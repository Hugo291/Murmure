import Accelerate

/// Transforme un bloc d'échantillons audio en `bandCount` bandes de spectre normalisées (0…1),
/// via FFT réelle (vDSP) + regroupement log + contrôle de gain automatique.
final class SpectrumAnalyzer {
    private let n: Int                 // taille FFT
    private let halfN: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var agc: Float = 0.02      // niveau de référence pour l'auto-gain
    private var noiseFloor: [Float] = []
    private var gate: Float = 0        // porte de voix (0 = fermée, 1 = ouverte)
    private var noiseRMS: Float = 0.01 // niveau de bruit ambiant (RMS) adaptatif
    private var gateOpen = false       // état de la porte avec hystérésis

    init(fftSize: Int = 1024) {
        n = fftSize
        halfN = fftSize / 2
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// `samples` : audio mono float. Renvoie `bandCount` valeurs lissées 0…1.
    func bands(from samples: [Float], bandCount: Int) -> [Float] {
        guard !samples.isEmpty else { return [Float](repeating: 0, count: bandCount) }

        // Volume global (RMS) du bloc, pour la détection de voix.
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

        // 1) Fenêtrage (Hann) sur n échantillons (zero-pad si trop court).
        var input = [Float](repeating: 0, count: n)
        let count = min(samples.count, n)
        for i in 0..<count { input[i] = samples[i] }
        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(n))

        // 2) FFT réelle → magnitudes.
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        real.withUnsafeMutableBufferPointer { realP in
            imag.withUnsafeMutableBufferPointer { imagP in
                var split = DSPSplitComplex(realp: realP.baseAddress!, imagp: imagP.baseAddress!)
                input.withUnsafeBufferPointer { inP in
                    inP.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { typed in
                        vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        // 3) Magnitudes (puissance) → amplitude.
        var amps = [Float](repeating: 0, count: halfN)
        var c: Float = 1.0 / Float(n)
        vDSP_vsmul(magnitudes, 1, &c, &amps, 1, vDSP_Length(halfN))
        for i in 0..<halfN { amps[i] = sqrtf(amps[i]) }

        // 4) Regroupement log-fréquentiel : la voix (graves/médiums) occupe plus de bandes.
        var out = [Float](repeating: 0, count: bandCount)
        let minBin = 1
        let maxBin = halfN - 1
        for b in 0..<bandCount {
            let f0 = Float(b) / Float(bandCount)
            let f1 = Float(b + 1) / Float(bandCount)
            let lo = Int(Float(minBin) * powf(Float(maxBin) / Float(minBin), f0))
            let hi = max(lo + 1, Int(Float(minBin) * powf(Float(maxBin) / Float(minBin), f1)))
            var sum: Float = 0, cnt: Float = 0
            for bin in lo..<min(hi, halfN) { sum += amps[bin]; cnt += 1 }
            out[b] = cnt > 0 ? sum / cnt : 0
        }

        // 5) Plancher de bruit par bande + soustraction spectrale (enlève le bruit de fond).
        if noiseFloor.count != bandCount { noiseFloor = [Float](repeating: 0, count: bandCount) }
        var cleaned = [Float](repeating: 0, count: bandCount)
        var peakC: Float = 0
        for b in 0..<bandCount {
            let a = out[b]
            // le plancher descend vite, monte très lentement → il suit le bruit de fond, pas la voix.
            if a < noiseFloor[b] { noiseFloor[b] = noiseFloor[b] * 0.9 + a * 0.1 }
            else { noiseFloor[b] = noiseFloor[b] * 0.999 + a * 0.001 }
            let c = max(0, a - noiseFloor[b] * 2.2)
            cleaned[b] = c
            peakC = max(peakC, c)
        }

        // 6) Détection de voix (VAD) sur le RMS global : plancher de bruit adaptatif + hystérésis.
        //    Tant que tu ne parles pas, la porte reste FERMÉE → barres à plat (rassurant).
        if rms < noiseRMS { noiseRMS = noiseRMS * 0.9 + rms * 0.1 } // descend vite vers le bruit
        else { noiseRMS = noiseRMS * 0.999 + rms * 0.001 }          // monte très lentement
        let nf = max(noiseRMS, 1e-5)
        if gateOpen {
            if rms < nf * 2.0 { gateOpen = false }                 // retombe près du bruit → ferme
        } else if rms > nf * 3.5 && rms > 0.005 {                  // dépasse franchement le bruit → ouvre
            gateOpen = true
        }
        let target: Float = gateOpen ? 1.0 : 0.0
        gate += (target - gate) * (target > gate ? 0.5 : 0.18)     // attaque rapide, relâchement doux

        // 7) Normalisation bornée (le gain n'explose pas dans le silence) × porte.
        agc = max(peakC, agc * 0.90)
        let norm = max(agc, 0.006)
        for b in 0..<bandCount {
            var v = cleaned[b] / norm
            v = powf(min(v, 1.3), 0.7)
            out[b] = min(v, 1.0) * gate
        }
        return out
    }

    /// À appeler au début d'un enregistrement pour repartir d'un plancher de bruit propre.
    func reset() {
        agc = 0.02
        gate = 0
        noiseFloor = []
        noiseRMS = 0.01
        gateOpen = false
    }
}
