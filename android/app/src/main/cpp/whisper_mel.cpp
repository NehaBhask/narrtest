#include <jni.h>
#include <cmath>
#include <vector>
#include <algorithm>

// Whisper mel spectrogram: PCM float32 → [80 × 3000] log-mel
// Matches whisper/audio.py exactly:
//   n_fft=400, hop=160, n_mels=80, sr=16000, fmax=8000

static const int N_FFT    = 400;
static const int FFT_N    = 512; // next power-of-2
static const int HOP      = 160;
static const int N_MELS   = 80;
static const int N_FRAMES = 3000;
static const int SR       = 16000;

static void fft(std::vector<float>& re, std::vector<float>& im) {
    int n = re.size();
    // bit-reversal
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { std::swap(re[i], re[j]); std::swap(im[i], im[j]); }
    }
    for (int len = 2; len <= n; len <<= 1) {
        float ang = -2.0f * M_PI / len;
        float wRe = cosf(ang), wIm = sinf(ang);
        for (int i = 0; i < n; i += len) {
            float cRe = 1, cIm = 0;
            for (int k = 0; k < len / 2; k++) {
                float uR = re[i+k], uI = im[i+k];
                float vR = re[i+k+len/2]*cRe - im[i+k+len/2]*cIm;
                float vI = re[i+k+len/2]*cIm + im[i+k+len/2]*cRe;
                re[i+k] = uR+vR; im[i+k] = uI+vI;
                re[i+k+len/2] = uR-vR; im[i+k+len/2] = uI-vI;
                float nR = cRe*wRe - cIm*wIm;
                cIm = cRe*wIm + cIm*wRe; cRe = nR;
            }
        }
    }
}

static std::vector<std::vector<float>> buildMelFilters() {
    const int fftBins = N_FFT / 2 + 1; // 201
    auto hzToMel = [](float hz){ return 2595.0f * log10f(1.0f + hz/700.0f); };
    auto melToHz = [](float mel){ return 700.0f * (powf(10.0f, mel/2595.0f) - 1.0f); };

    float melMin = hzToMel(0), melMax = hzToMel(8000);
    std::vector<float> melPts(N_MELS + 2);
    for (int i = 0; i < N_MELS + 2; i++)
        melPts[i] = melMin + i * (melMax - melMin) / (N_MELS + 1);

    std::vector<int> bins(N_MELS + 2);
    for (int i = 0; i < N_MELS + 2; i++)
        bins[i] = std::min((int)(melToHz(melPts[i]) * (N_FFT + 1) / SR), fftBins - 1);

    std::vector<std::vector<float>> filters(N_MELS, std::vector<float>(fftBins, 0));
    for (int m = 0; m < N_MELS; m++) {
        for (int k = bins[m]; k < bins[m+1]; k++)
            if (bins[m+1] > bins[m])
                filters[m][k] = (float)(k - bins[m]) / (bins[m+1] - bins[m]);
        for (int k = bins[m+1]; k < bins[m+2]; k++)
            if (bins[m+2] > bins[m+1])
                filters[m][k] = (float)(bins[m+2] - k) / (bins[m+2] - bins[m+1]);
    }
    return filters;
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_narrator_NarratorPlugin_computeMelSpectrogram(
        JNIEnv* env, jobject /* this */, jfloatArray pcmSamples) {

    // Get PCM input
    jsize len = env->GetArrayLength(pcmSamples);
    std::vector<float> samples(len);
    env->GetFloatArrayRegion(pcmSamples, 0, len, samples.data());

    // Pad to 30s
    const int TARGET = 480000;
    const int PAD    = N_FFT / 2;
    std::vector<float> padded(TARGET + 2 * PAD, 0.0f);
    int copy = std::min((int)samples.size(), TARGET);
    std::copy(samples.begin(), samples.begin() + copy, padded.begin() + PAD);

    // Hann window
    std::vector<float> hann(N_FFT);
    for (int i = 0; i < N_FFT; i++)
        hann[i] = 0.5f * (1.0f - cosf(2.0f * M_PI * i / N_FFT));

    // Mel filterbank
    auto melFilters = buildMelFilters();
    const int fftBins = N_FFT / 2 + 1;

    // Output: [N_MELS * N_FRAMES]
    std::vector<float> mel(N_MELS * N_FRAMES);

    for (int frame = 0; frame < N_FRAMES; frame++) {
        int start = frame * HOP;
        std::vector<float> re(FFT_N, 0), im(FFT_N, 0);
        for (int i = 0; i < N_FFT; i++)
            re[i] = padded[start + i] * hann[i];

        fft(re, im);

        for (int m = 0; m < N_MELS; m++) {
            float energy = 0;
            for (int k = 0; k < fftBins; k++)
                energy += melFilters[m][k] * (re[k]*re[k] + im[k]*im[k]);
            mel[m * N_FRAMES + frame] = energy < 1e-10f ? -10.0f : log10f(energy);
        }
    }

    // Whisper normalisation
    float logMax = -1e20f;
    for (float v : mel) if (v > logMax) logMax = v;
    for (float& v : mel) {
        v = (v - logMax) / 4.0f + 1.0f;
        if (v < -1.0f) v = -1.0f;
    }

    jfloatArray result = env->NewFloatArray(N_MELS * N_FRAMES);
    env->SetFloatArrayRegion(result, 0, N_MELS * N_FRAMES, mel.data());
    return result;
}