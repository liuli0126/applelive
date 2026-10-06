#pragma once

#include <cstdint>
#include <vector>

namespace applelive {

inline constexpr char kUsbMagic[] = "ALUSB1\r\n";
inline constexpr std::uint32_t kMaxPacket = 8u * 1024u * 1024u;

inline void put_le32(std::vector<std::uint8_t> &out, std::uint32_t value)
{
    out.push_back(static_cast<std::uint8_t>(value));
    out.push_back(static_cast<std::uint8_t>(value >> 8));
    out.push_back(static_cast<std::uint8_t>(value >> 16));
    out.push_back(static_cast<std::uint8_t>(value >> 24));
}

inline void put_be32(std::vector<std::uint8_t> &out, std::uint32_t value)
{
    out.push_back(static_cast<std::uint8_t>(value >> 24));
    out.push_back(static_cast<std::uint8_t>(value >> 16));
    out.push_back(static_cast<std::uint8_t>(value >> 8));
    out.push_back(static_cast<std::uint8_t>(value));
}

inline std::vector<std::uint8_t> frame(const std::vector<std::uint8_t> &payload)
{
    std::vector<std::uint8_t> result;
    result.reserve(payload.size() + 4);
    put_be32(result, static_cast<std::uint32_t>(payload.size()));
    result.insert(result.end(), payload.begin(), payload.end());
    return result;
}

} // namespace applelive
