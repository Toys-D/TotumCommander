#include <gtest/gtest.h>

#include <curl/curl.h>

#include "fcxl/common/error.h"
#include "fcxl/network/ftp_client.h"

using fcxl::common::ErrorCode;
using fcxl::network::describe_connect_failure;

// Вход не удался: что человек прочтёт вместо английского «Login denied».

TEST(FtpLoginFailure, ServerRefusedSaysItInTheServersOwnWords) {
    const auto f = describe_connect_failure(CURLE_LOGIN_DENIED,
                                            "530 User cannot log in.\r\n", "Login denied");
    EXPECT_EQ(f.code, ErrorCode::PermissionDenied);
    EXPECT_EQ(f.message, "530 User cannot log in.");
}

TEST(FtpLoginFailure, FiveThirtyIsRefusalEvenWhenCurlCallsItSomethingElse) {
    const auto f = describe_connect_failure(CURLE_WEIRD_SERVER_REPLY,
                                            "530 Authentication failed.", "Weird server reply");
    EXPECT_EQ(f.code, ErrorCode::PermissionDenied);
    EXPECT_EQ(f.message, "530 Authentication failed.");
}

TEST(FtpLoginFailure, OtherRefusalCodesCountToo) {
    for (const auto* reply : {"430 Invalid username or password", "532 Need account for storing"}) {
        const auto f = describe_connect_failure(CURLE_WEIRD_SERVER_REPLY, reply, "Weird server reply");
        EXPECT_EQ(f.code, ErrorCode::PermissionDenied) << reply;
    }
}

TEST(FtpLoginFailure, ConnectionDroppedRightAfterThePasswordIsALoginProblem) {
    // Сервер попросил пароль — и замолчал. Так закрывают связь на неверный пароль и так же
    // ведёт себя защита, забанившая адрес за неудачные попытки.
    const auto f = describe_connect_failure(CURLE_RECV_ERROR,
                                            "331 Password required for user\r\n",
                                            "Failure when receiving data from the peer");
    EXPECT_EQ(f.code, ErrorCode::PermissionDenied);
    EXPECT_EQ(f.message, "331 Password required for user");
}

TEST(FtpLoginFailure, BrokenLinkBeforeTheLoginIsNotALoginProblem) {
    const auto f = describe_connect_failure(CURLE_COULDNT_CONNECT, "", "Couldn't connect to server");
    EXPECT_EQ(f.code, ErrorCode::NetworkError);
    EXPECT_EQ(f.message, "Couldn't connect to server");
}

TEST(FtpLoginFailure, TheGreetingAloneIsNotARefusal) {
    // Успели поздороваться и умерли на списке файлов — это не отказ во входе.
    const auto f = describe_connect_failure(CURLE_RECV_ERROR, "220 Totum test FTP",
                                            "Failure when receiving data from the peer");
    EXPECT_EQ(f.code, ErrorCode::NetworkError);
    EXPECT_EQ(f.message, "220 Totum test FTP");
}

TEST(FtpLoginFailure, WithoutAServerReplyCurlsOwnWordsAreUsed) {
    const auto f = describe_connect_failure(CURLE_LOGIN_DENIED, "   \r\n", "Login denied");
    EXPECT_EQ(f.code, ErrorCode::PermissionDenied);
    EXPECT_EQ(f.message, "Login denied");
}
