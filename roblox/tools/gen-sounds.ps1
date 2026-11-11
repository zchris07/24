# Renders the web version's three Web Audio cues to WAV files, sample for
# sample: same oscillators, envelopes and biquad filters.
#   powershell -ExecutionPolicy Bypass -File tools\gen-sounds.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'sounds'
New-Item -ItemType Directory -Force $outDir | Out-Null

Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class Synth24 {
    const int SR = 44100;

    static double[] noise;
    static double[] Noise() {
        if (noise == null) {
            var rng = new Random(24);
            int len = (int)(SR * 0.24);
            noise = new double[len];
            for (int i = 0; i < len; i++) noise[i] = (rng.NextDouble() * 2 - 1) * (1 - (double)i / len);
        }
        return noise;
    }

    // setValueAtTime(0.0001) + two exponential ramps
    static double Env(double t, double t0, double peak, double attack, double decay) {
        if (t < t0) return 0;
        double a = t - t0;
        if (a <= attack) return 0.0001 * Math.Pow(peak / 0.0001, a / attack);
        if (a <= attack + decay) return peak * Math.Pow(0.0001 / peak, (a - attack) / decay);
        return 0.0001;
    }

    static double ExpRamp(double t, double t0, double v0, double t1, double v1) {
        if (t <= t0) return v0;
        if (t >= t1) return v1;
        return v0 * Math.Pow(v1 / v0, (t - t0) / (t1 - t0));
    }

    class Biquad {
        double b0, b1, b2, a1, a2, x1, x2, y1, y2;
        public void Set(string type, double freq, double q) {
            double w0 = 2 * Math.PI * freq / SR;
            double cos = Math.Cos(w0), sin = Math.Sin(w0);
            double alpha, a0;
            if (type == "highpass") {
                // Web Audio treats lowpass/highpass Q as dB
                alpha = sin / (2 * Math.Pow(10, q / 20));
                b0 = (1 + cos) / 2; b1 = -(1 + cos); b2 = (1 + cos) / 2;
                a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha;
            } else {
                alpha = sin / (2 * q);
                b0 = alpha; b1 = 0; b2 = -alpha;
                a0 = 1 + alpha; a1 = -2 * cos; a2 = 1 - alpha;
            }
            b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0;
        }
        public double Run(double x) {
            double y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = x; y2 = y1; y1 = y;
            return y;
        }
    }

    // playEquationAddSound
    public static double[] CardAdd() {
        int n = (int)(SR * 0.12);
        var o = new double[n];
        double phase = 0;
        var hp = new Biquad();
        hp.Set("highpass", 1000, 1);
        var nz = Noise();
        for (int i = 0; i < n; i++) {
            double t = (double)i / SR;
            double v = 0;
            if (t < 0.08) {
                double f = ExpRamp(t, 0, 240, 0.05, 118);
                phase += f / SR;
                double p = phase - Math.Floor(phase);
                double tri = p < 0.25 ? 4 * p : (p < 0.75 ? 2 - 4 * p : 4 * p - 4);
                v += tri * Env(t, 0, 0.13, 0.003, 0.05);
            }
            if (t < 0.03) {
                double g = ExpRamp(t, 0, 0.0001, 0.002, 0.04);
                if (t > 0.002) g = ExpRamp(t, 0.002, 0.04, 0.02, 0.0001);
                v += hp.Run(nz[i]) * g;
            }
            o[i] = v;
        }
        return o;
    }

    // playSubmitSound
    public static double[] Submit() {
        int n = (int)(SR * 0.26);
        var o = new double[n];
        double[] freqs = { 523.25, 783.99 };
        double[] offs = { 0, 0.075 };
        for (int i = 0; i < n; i++) {
            double t = (double)i / SR;
            double v = 0;
            for (int k = 0; k < 2; k++) {
                double s = t - offs[k];
                if (s >= 0 && s < 0.16) v += Math.Sin(2 * Math.PI * freqs[k] * s) * Env(t, offs[k], 0.13, 0.006, 0.13);
            }
            o[i] = v;
        }
        return o;
    }

    // playDealSound
    public static double[] Deal() {
        int n = (int)(SR * 0.1);
        var o = new double[n];
        var bp = new Biquad();
        var nz = Noise();
        for (int i = 0; i < n; i++) {
            double t = (double)i / SR;
            if (t >= 0.08) { o[i] = 0; continue; }
            bp.Set("bandpass", ExpRamp(t, 0, 2200, 0.05, 1300), 1.4);
            double g = t < 0.006 ? ExpRamp(t, 0, 0.0001, 0.006, 0.13) : ExpRamp(t, 0.006, 0.13, 0.06, 0.0001);
            o[i] = bp.Run(nz[i]) * g;
        }
        return o;
    }

    public static void WriteWav(string path, double[] data, double gain) {
        using (var fs = new FileStream(path, FileMode.Create))
        using (var w = new BinaryWriter(fs)) {
            int n = data.Length;
            w.Write(new char[] { 'R', 'I', 'F', 'F' });
            w.Write(36 + n * 2);
            w.Write(new char[] { 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ' });
            w.Write(16); w.Write((short)1); w.Write((short)1);
            w.Write(SR); w.Write(SR * 2); w.Write((short)2); w.Write((short)16);
            w.Write(new char[] { 'd', 'a', 't', 'a' });
            w.Write(n * 2);
            for (int i = 0; i < n; i++) {
                double v = Math.Max(-1, Math.Min(1, data[i] * gain));
                w.Write((short)Math.Round(v * 32767));
            }
        }
    }
}
'@

# One shared gain keeps the three cues at the same relative loudness as the web version.
$gain = 2.5
[Synth24]::WriteWav((Join-Path $outDir 'card-add.wav'), [Synth24]::CardAdd(), $gain)
[Synth24]::WriteWav((Join-Path $outDir 'submit.wav'), [Synth24]::Submit(), $gain)
[Synth24]::WriteWav((Join-Path $outDir 'deal.wav'), [Synth24]::Deal(), $gain)
Get-ChildItem $outDir | Select-Object Name, Length
