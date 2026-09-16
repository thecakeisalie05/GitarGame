#pragma once

#include <opusfile.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <limits>
#include <optional>
#include <string>
#include <vector>

struct OpusMixResult {
    std::vector<unsigned char> wavBytes;
    int stemCount = 0;
    double durationSeconds = 0.0;
};

namespace opusmix {

inline std::string lowerCopy(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

inline bool shouldInclude(const std::filesystem::path& path) {
    const std::string ext = lowerCopy(path.extension().string());
    if (ext != ".opus") return false;
    const std::string stem = lowerCopy(path.stem().string());
    return stem != "preview";
}

inline std::vector<unsigned char> readBytes(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return {};
    return std::vector<unsigned char>(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

inline void put16(std::vector<unsigned char>& out, size_t at, uint16_t value) {
    out[at] = static_cast<unsigned char>(value & 0xffU);
    out[at + 1] = static_cast<unsigned char>((value >> 8) & 0xffU);
}

inline void put32(std::vector<unsigned char>& out, size_t at, uint32_t value) {
    out[at] = static_cast<unsigned char>(value & 0xffU);
    out[at + 1] = static_cast<unsigned char>((value >> 8) & 0xffU);
    out[at + 2] = static_cast<unsigned char>((value >> 16) & 0xffU);
    out[at + 3] = static_cast<unsigned char>((value >> 24) & 0xffU);
}

inline std::optional<OpusMixResult> mixDirectory(const std::filesystem::path& directory, std::string& error) {
    std::vector<std::filesystem::path> files;
    std::error_code ec;
    for (const auto& entry : std::filesystem::directory_iterator(directory, ec)) {
        if (entry.is_regular_file(ec) && shouldInclude(entry.path())) files.push_back(entry.path());
    }
    if (files.empty()) { error = "No .opus stems found"; return std::nullopt; }
    std::sort(files.begin(), files.end());

    constexpr int sampleRate = 48000;
    constexpr int channels = 2;
    opus_int64 maxFrames = 0;

    struct Source {
        std::filesystem::path path;
        std::vector<unsigned char> bytes;
        OggOpusFile* file = nullptr;
        opus_int64 frames = 0;
    };
    std::vector<Source> sources;
    sources.reserve(files.size());

    for (const auto& path : files) {
        Source source;
        source.path = path;
        source.bytes = readBytes(path);
        if (source.bytes.empty()) continue;
        int openError = 0;
        source.file = op_open_memory(source.bytes.data(), static_cast<opus_int32>(source.bytes.size()), &openError);
        if (!source.file) continue;
        source.frames = op_pcm_total(source.file, -1);
        if (source.frames <= 0) { op_free(source.file); source.file = nullptr; continue; }
        maxFrames = std::max(maxFrames, source.frames);
        sources.push_back(std::move(source));
    }

    if (sources.empty() || maxFrames <= 0) {
        error = "Could not decode any .opus stems";
        return std::nullopt;
    }
    if (maxFrames > static_cast<opus_int64>(sampleRate) * 60 * 60) {
        for (auto& source : sources) if (source.file) op_free(source.file);
        error = "Opus song is longer than the current one-hour safety limit";
        return std::nullopt;
    }

    const size_t frameCount = static_cast<size_t>(maxFrames);
    if (frameCount > std::numeric_limits<size_t>::max() / (channels * sizeof(float))) {
        for (auto& source : sources) if (source.file) op_free(source.file);
        error = "Opus mix is too large for memory";
        return std::nullopt;
    }
    std::vector<float> mix(frameCount * channels, 0.0f);
    constexpr int chunkFrames = 4096;
    std::vector<float> chunk(static_cast<size_t>(chunkFrames) * channels);

    for (auto& source : sources) {
        size_t writeFrame = 0;
        for (;;) {
            const int got = op_read_float_stereo(source.file, chunk.data(), static_cast<int>(chunk.size()));
            if (got == 0) break;
            if (got < 0) {
                // Recoverable packet holes are allowed by opusfile; other negative errors
                // skip this packet instead of destroying the entire song load.
                if (got == OP_HOLE) continue;
                break;
            }
            const size_t frames = std::min<size_t>(static_cast<size_t>(got), frameCount - std::min(writeFrame, frameCount));
            for (size_t i = 0; i < frames; ++i) {
                mix[(writeFrame + i) * 2] += chunk[i * 2];
                mix[(writeFrame + i) * 2 + 1] += chunk[i * 2 + 1];
            }
            writeFrame += frames;
            if (writeFrame >= frameCount) break;
        }
        op_free(source.file);
        source.file = nullptr;
    }

    float peak = 0.0f;
    for (const float sample : mix) peak = std::max(peak, std::abs(sample));
    const float scale = peak > 0.98f ? 0.98f / peak : 1.0f;

    const uint64_t pcmBytes64 = static_cast<uint64_t>(frameCount) * channels * sizeof(int16_t);
    if (pcmBytes64 > 0xffffffffULL - 44ULL) { error = "Decoded Opus mix exceeds WAV size limit"; return std::nullopt; }
    const uint32_t pcmBytes = static_cast<uint32_t>(pcmBytes64);
    std::vector<unsigned char> wav(static_cast<size_t>(44) + pcmBytes, 0);
    std::copy_n(reinterpret_cast<const unsigned char*>("RIFF"), 4, wav.begin());
    put32(wav, 4, 36U + pcmBytes);
    std::copy_n(reinterpret_cast<const unsigned char*>("WAVEfmt "), 8, wav.begin() + 8);
    put32(wav, 16, 16);       // PCM fmt chunk
    put16(wav, 20, 1);        // PCM integer
    put16(wav, 22, channels);
    put32(wav, 24, sampleRate);
    put32(wav, 28, sampleRate * channels * static_cast<int>(sizeof(int16_t)));
    put16(wav, 32, channels * static_cast<int>(sizeof(int16_t)));
    put16(wav, 34, 16);
    std::copy_n(reinterpret_cast<const unsigned char*>("data"), 4, wav.begin() + 36);
    put32(wav, 40, pcmBytes);

    size_t out = 44;
    for (const float sample : mix) {
        const float value = std::clamp(sample * scale, -1.0f, 1.0f);
        const int16_t pcm = static_cast<int16_t>(std::lrint(value * 32767.0f));
        wav[out++] = static_cast<unsigned char>(static_cast<uint16_t>(pcm) & 0xffU);
        wav[out++] = static_cast<unsigned char>((static_cast<uint16_t>(pcm) >> 8) & 0xffU);
    }

    OpusMixResult result;
    result.wavBytes = std::move(wav);
    result.stemCount = static_cast<int>(sources.size());
    result.durationSeconds = static_cast<double>(frameCount) / static_cast<double>(sampleRate);
    error.clear();
    return result;
}

} // namespace opusmix
