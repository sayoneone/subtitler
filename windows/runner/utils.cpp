#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>
#include <vector>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

std::wstring GetInstanceName() {
  const std::wstring fallback = L"ru.subtitler.subtitler";
  std::vector<wchar_t> path(32768);
  const DWORD length = ::GetModuleFileNameW(
      nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    return fallback;
  }
  DWORD unused = 0;
  const DWORD size = ::GetFileVersionInfoSizeW(path.data(), &unused);
  if (size == 0) {
    return fallback;
  }
  std::vector<BYTE> info(size);
  if (!::GetFileVersionInfoW(path.data(), 0, size, info.data())) {
    return fallback;
  }
  // Runner.rc keeps the strings in the "040904e4" block.
  auto query = [&info](const wchar_t* field) {
    const std::wstring key =
        std::wstring(L"\\StringFileInfo\\040904e4\\") + field;
    wchar_t* value = nullptr;
    UINT chars = 0;
    if (!::VerQueryValueW(info.data(), key.c_str(),
                          reinterpret_cast<void**>(&value), &chars) ||
        value == nullptr || chars == 0) {
      return std::wstring();
    }
    return std::wstring(value);
  };
  const std::wstring company = query(L"CompanyName");
  const std::wstring product = query(L"ProductName");
  if (company.empty() || product.empty()) {
    return fallback;
  }
  std::wstring name = company + L"." + product;
  // Kernel object names may not contain backslashes after the namespace.
  for (wchar_t& c : name) {
    if (c == L'\\') {
      c = L'_';
    }
  }
  return name;
}
