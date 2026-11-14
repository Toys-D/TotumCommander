#include <gtest/gtest.h>

#include <curl/curl.h>

#include <string>

#include "fcxl/network/server_trust.h"

using fcxl::network::ServerKeyVerdict;
using fcxl::network::format_host_key_fingerprint;
using fcxl::network::judge_server_key;
using fcxl::network::judge_tls_failure;
using fcxl::network::parse_public_key_pin;

// Тот ли это сервер. Пока ответа нет, ему нельзя говорить ни имени, ни пароля.

// MARK: отпечаток ключа узла SSH

TEST(ServerTrust, HostKeyFingerprintLooksTheWaySshKeygenPrintsIt) {
    std::string raw;
    for (int i = 0; i < 32; ++i) raw.push_back(static_cast<char>(i));
    EXPECT_EQ(format_host_key_fingerprint(raw),
              "SHA256:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8");
}

TEST(ServerTrust, HostKeyFingerprintKeepsPlusAndSlashAndDropsThePadding) {
    EXPECT_EQ(format_host_key_fingerprint(std::string(32, '\xff')),
              "SHA256://////////////////////////////////////////8");
    const std::string raw = std::string("\xfb\xef\xbe", 3) + std::string(29, '\0');
    EXPECT_EQ(format_host_key_fingerprint(raw),
              "SHA256:++++AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
}

TEST(ServerTrust, HashOfTheWrongLengthGivesNoFingerprint) {
    // SHA-256 — это ровно 32 байта. Всё остальное — не тот хеш, и сверять с ним нечего.
    EXPECT_EQ(format_host_key_fingerprint(""), "");
    EXPECT_EQ(format_host_key_fingerprint(std::string(20, 'a')), "");
    EXPECT_EQ(format_host_key_fingerprint(std::string(33, 'a')), "");
}

// MARK: вердикт

TEST(ServerTrust, ServerSeenForTheFirstTimeIsUnknown) {
    EXPECT_EQ(judge_server_key("SHA256:abc", ""), ServerKeyVerdict::Unknown);
}

TEST(ServerTrust, TheSameKeyIsTrusted) {
    EXPECT_EQ(judge_server_key("SHA256:abc", "SHA256:abc"), ServerKeyVerdict::Trusted);
}

TEST(ServerTrust, AnotherKeyMeansTheServerChanged) {
    EXPECT_EQ(judge_server_key("SHA256:abd", "SHA256:abc"), ServerKeyVerdict::Changed);
    // base64 различает большие и малые буквы: «почти тот же» ключ — другой ключ.
    EXPECT_EQ(judge_server_key("SHA256:ABC", "SHA256:abc"), ServerKeyVerdict::Changed);
}

TEST(ServerTrust, ServerThatShowedNoKeyIsNeverTrusted) {
    EXPECT_EQ(judge_server_key("", ""), ServerKeyVerdict::Unknown);
    EXPECT_EQ(judge_server_key("", "SHA256:abc"), ServerKeyVerdict::Changed);
}

// MARK: FTPS — хеш открытого ключа из подробного вывода libcurl

TEST(ServerTrust, PinIsReadFromTheLineCurlPrints) {
    EXPECT_EQ(parse_public_key_pin(
                  " public key hash: sha256//YhKJKSzoTt2b5FP18fvpHo7fJYqQCjAa3HWY3tvRMwE=\n"),
              "sha256//YhKJKSzoTt2b5FP18fvpHo7fJYqQCjAa3HWY3tvRMwE=");
}

TEST(ServerTrust, OtherLinesCarryNoPin) {
    EXPECT_EQ(parse_public_key_pin("SSL connection using TLSv1.3 / AEAD-AES256-GCM-SHA384\n"), "");
    EXPECT_EQ(parse_public_key_pin(""), "");
}

TEST(ServerTrust, AnythingButOneWholeHashIsNotAPin) {
    // Эта строка попадает в настройки и возвращается в libcurl привязкой. В привязке «;»
    // разделяет несколько ключей — постороннему знаку в ней делать нечего.
    EXPECT_EQ(parse_public_key_pin(" public key hash: sha256//\n"), "");
    EXPECT_EQ(parse_public_key_pin(" public key hash: sha256//abc=\n"), "");
    EXPECT_EQ(parse_public_key_pin(
                  " public key hash: sha256//YhKJKSzoTt2b5FP18fvpHo7fJYqQCjAa3HWY3tvRMw;=\n"), "");
    EXPECT_EQ(parse_public_key_pin(
                  " public key hash: sha256//YhKJKSzoTt2b5FP18fvpHo7fJYqQCjAa3HWY3tvRMwE=;x\n"), "");
}

// MARK: FTPS — что значит отказ libcurl

TEST(ServerTrust, FailedCertificateCheckWithoutAPinMeansUnknownServer) {
    const auto verdict = judge_tls_failure(CURLE_PEER_FAILED_VERIFICATION, false);
    ASSERT_TRUE(verdict.has_value());
    EXPECT_EQ(*verdict, ServerKeyVerdict::Unknown);
}

TEST(ServerTrust, PinMismatchMeansTheKeyChanged) {
    const auto verdict = judge_tls_failure(CURLE_SSL_PINNEDPUBKEYNOTMATCH, true);
    ASSERT_TRUE(verdict.has_value());
    EXPECT_EQ(*verdict, ServerKeyVerdict::Changed);
}

TEST(ServerTrust, OtherFailuresAreNotAboutTheKey) {
    EXPECT_FALSE(judge_tls_failure(CURLE_OK, false).has_value());
    EXPECT_FALSE(judge_tls_failure(CURLE_LOGIN_DENIED, false).has_value());
    EXPECT_FALSE(judge_tls_failure(CURLE_COULDNT_CONNECT, true).has_value());
    EXPECT_FALSE(judge_tls_failure(CURLE_SSL_CONNECT_ERROR, false).has_value());
    EXPECT_FALSE(judge_tls_failure(CURLE_OPERATION_TIMEDOUT, true).has_value());
}
