#include <libraw/libraw.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <locale>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr unsigned width = 6024;
constexpr unsigned height = 4016;
constexpr std::array<int, 4> cfa = {0, 1, 3, 2};
constexpr std::array<unsigned, 4> rgb = {0, 1, 1, 2};
constexpr char channels[] = "RGB";

void checkLibRaw(int result, const char *step) {
    if (result != LIBRAW_SUCCESS) {
        throw std::runtime_error(std::string(step) + ": " + libraw_strerror(result));
    }
}

void validateGeometry(LibRaw &raw) {
    const auto &image = raw.imgdata.rawdata;
    const auto &size = image.sizes;
    if (!image.raw_image || image.float_image || image.iparams.dng_version ||
        std::strncmp(image.iparams.cdesc, "RGBG", sizeof(image.iparams.cdesc)) != 0 ||
        size.width != width || size.height != height || size.raw_width != 6072 || size.raw_height != height ||
        size.left_margin != 0 || size.top_margin != 0 || size.flip != 0 ||
        size.raw_pitch % sizeof(std::uint16_t) != 0 ||
        size.raw_pitch / sizeof(std::uint16_t) < size.raw_width ||
        size.raw_inset_crops[0].cleft != 12 || size.raw_inset_crops[0].ctop != 8 ||
        size.raw_inset_crops[0].cwidth != 6000 || size.raw_inset_crops[0].cheight != 4000) {
        throw std::runtime_error("Use an original, unrotated, full-size Panasonic DC-S1H RW2 from this film setup.");
    }
    for (int row = 0; row < 8; ++row) {
        if (raw.COLOR(row, 0) != cfa[2 * (row % 2)] || raw.COLOR(row, 1) != cfa[2 * (row % 2) + 1]) {
            throw std::runtime_error("The RW2 Bayer pattern differs from the verified S1H film setup.");
        }
    }
}

double percentile999(std::vector<double> &samples) {
    const double index = 0.999 * (samples.size() - 1);
    const auto upper = samples.begin() + static_cast<std::size_t>(std::ceil(index));
    std::nth_element(samples.begin(), upper, samples.end());
    const double weight = index - std::floor(index);
    if (weight == 0) {
        return *upper;
    }
    const double lower = *std::max_element(samples.begin(), upper);
    return lower + weight * (*upper - lower);
}

void measure(const char *path, unsigned selected) {
    LibRaw raw;
    raw.imgdata.rawparams.max_raw_memory_mb = 512;
    checkLibRaw(raw.open_file(path), "Cannot open RW2");
    const auto &camera = raw.imgdata.idata;
    if (std::strncmp(camera.make, "Panasonic", sizeof(camera.make)) != 0 ||
        std::strncmp(camera.model, "DC-S1H", sizeof(camera.model)) != 0) {
        throw std::runtime_error("Only original Panasonic DC-S1H RW2 files from this film setup are supported.");
    }
    checkLibRaw(raw.unpack(), "Cannot decode RW2");
    validateGeometry(raw);

    const auto &exposure = raw.imgdata.other;
    const std::array<double, 3> settings = {exposure.iso_speed, exposure.aperture, exposure.shutter};
    if (!std::all_of(settings.begin(), settings.end(), [](double value) { return std::isfinite(value) && value > 0; })) {
        throw std::runtime_error("The RW2 must include valid ISO, aperture, and shutter metadata.");
    }

    const auto &image = raw.imgdata.rawdata;
    const auto &color = image.color;
    const unsigned white = color.maximum;
    const unsigned blackRows = color.cblack[4];
    const unsigned blackColumns = color.cblack[5];
    if (white == 0 || white > UINT16_MAX || (blackRows == 0) != (blackColumns == 0) ||
        static_cast<std::uint64_t>(blackRows) * blackColumns > LIBRAW_CBLACK_SIZE - 6) {
        throw std::runtime_error("The RW2 contains invalid black or white levels.");
    }

    std::array<unsigned, 4> limits{};
    for (unsigned site = 0; site < limits.size(); ++site) {
        const unsigned calibrated = color.linear_max[cfa[site]];
        limits[site] = calibrated > 0 ? std::min(calibrated, white) : white;
    }
    const std::size_t stride = image.sizes.raw_pitch / sizeof(std::uint16_t);

    // Use the same unrotated, visible-sensor rebate rectangle verified in NegPy.
    const auto left = static_cast<unsigned>(std::lround(0.445 * width));
    const auto right = static_cast<unsigned>(std::lround(0.56 * width));
    const auto top = static_cast<unsigned>(std::lround(0.007 * height));
    const auto bottom = static_cast<unsigned>(std::lround(0.025 * height));
    std::array<std::vector<double>, 3> levels;
    for (unsigned y = top; y < bottom; ++y) {
        const auto *row = image.raw_image + y * stride;
        for (unsigned x = left; x < right; ++x) {
            const unsigned site = 2 * (y % 2) + x % 2;
            std::uint64_t black = static_cast<std::uint64_t>(color.black) + color.cblack[cfa[site]];
            if (blackRows > 0) {
                black += color.cblack[6 + (y % blackRows) * blackColumns + x % blackColumns];
            }
            const unsigned limit = limits[site];
            if (black >= limit) {
                throw std::runtime_error("The RW2 black level is above its sensor linearity limit.");
            }
            const unsigned code = row[x];
            levels[rgb[site]].push_back(static_cast<double>(code > black ? code - black : 0) / (limit - black));
        }
    }

    // Count individual Bayer sites reaching their declared limit across the full visible image.
    std::size_t clippedPixels = 0;
    for (unsigned y = 0; y < height; ++y) {
        const auto *row = image.raw_image + y * stride;
        const unsigned phase = 2 * (y % 2);
        for (unsigned x = 0; x < width; x += 2) {
            clippedPixels += row[x] >= limits[phase];
            clippedPixels += row[x + 1] >= limits[phase + 1];
        }
    }

    const std::array<double, 3> p999 = {percentile999(levels[0]), percentile999(levels[1]), percentile999(levels[2])};
    const auto dominant = std::max_element(p999.begin(), p999.end()) - p999.begin();
    std::cout.imbue(std::locale::classic());
    std::cout << std::setprecision(12)
              << "{\"p999\":" << p999[selected] << ",\"clippedPixels\":" << clippedPixels
              << ",\"camera\":\"Panasonic DC-S1H\",\"iso\":" << settings[0]
              << ",\"aperture\":" << settings[1] << ",\"shutter\":" << settings[2]
              << ",\"dominant\":\"" << channels[dominant] << "\"}\n";
}

} // namespace

int main(int argc, char *argv[]) {
    const char *channel = argc == 3 && std::strlen(argv[2]) == 1 ? std::strchr(channels, argv[2][0]) : nullptr;
    if (!channel || argv[1][0] != '/') {
        std::cerr << "Usage: MeasureNegPyExposure /absolute/image.RW2 R|G|B\n";
        return 2;
    }

    try {
        measure(argv[1], static_cast<unsigned>(channel - channels));
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
