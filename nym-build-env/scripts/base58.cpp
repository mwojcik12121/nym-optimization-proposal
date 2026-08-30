#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

int alphabet_index(char character) {
  static const std::string alphabet =
      "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  const std::size_t position = alphabet.find(character);
  if (position == std::string::npos) {
    throw std::runtime_error("invalid Base58 character");
  }
  return static_cast<int>(position);
}

std::vector<std::uint8_t> decode_base58(const std::string &text) {
  std::size_t leading_zeroes = 0;
  while (leading_zeroes < text.size() && text[leading_zeroes] == '1') {
    ++leading_zeroes;
  }

  std::vector<std::uint8_t> work((text.size() * 733U) / 1000U + 1U, 0U);
  std::size_t used = 0;

  for (char character : text) {
    int carry = alphabet_index(character);
    std::size_t index = 0;

    for (auto iterator = work.rbegin();
         (carry != 0 || index < used) && iterator != work.rend();
         ++iterator, ++index) {
      carry += 58 * static_cast<int>(*iterator);
      *iterator = static_cast<std::uint8_t>(carry % 256);
      carry /= 256;
    }

    if (carry != 0) {
      throw std::runtime_error("Base58 value is too large");
    }
    used = index;
  }

  auto first = work.begin() + static_cast<std::ptrdiff_t>(work.size() - used);
  while (first != work.end() && *first == 0U) {
    ++first;
  }

  std::vector<std::uint8_t> result(leading_zeroes, 0U);
  result.insert(result.end(), first, work.end());
  return result;
}

void print_json(const std::vector<std::uint8_t> &bytes) {
  std::cout << '[';
  for (std::size_t index = 0; index < bytes.size(); ++index) {
    if (index != 0U) {
      std::cout << ',';
    }
    std::cout << static_cast<unsigned int>(bytes[index]);
  }
  std::cout << "]\n";
}

int main(int argc, char **argv) {
  if (argc != 2) {
    std::cerr << "usage: nym-base58 BASE58_VALUE\n";
    return 2;
  }

  try {
    print_json(decode_base58(argv[1]));
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "nym-base58: " << error.what() << '\n';
    return 1;
  }
}
