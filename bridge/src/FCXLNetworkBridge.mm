#import "FCXLNetworkBridge.h"
#include "fcxl/network/ftp_client.h"
#include "fcxl/network/sftp_client.h"
#include <memory>
#include <optional>

using namespace fcxl;

NSString *const FCXLServerKeyStatusKey = @"FCXLServerKeyStatus";
NSString *const FCXLServerKeyFingerprintKey = @"FCXLServerKeyFingerprint";
NSString *const FCXLServerKeyTypeKey = @"FCXLServerKeyType";
NSString *const FCXLServerKeyReasonKey = @"FCXLServerKeyReason";

// MARK: - FCXLRemoteEntry

@implementation FCXLRemoteEntry
@end

static NSError* makeError(const common::Error& err) {
    return [NSError errorWithDomain:@"com.fcxl.network"
                               code:static_cast<NSInteger>(err.code)
                           userInfo:@{NSLocalizedDescriptionKey: @(err.message.c_str())}];
}

/// Ошибка подключения. Если оно остановилось из-за ключа сервера, к ошибке прикладывается
/// то, что сервер предъявил: по этому верхний слой отличает «сервер не подтверждён» от
/// обычного отказа сети и показывает человеку отпечаток.
static NSError* makeConnectError(const common::Error& err,
                                 const std::optional<network::ServerKeyReport>& key) {
    if (!key || key->verdict == network::ServerKeyVerdict::Trusted) return makeError(err);
    NSString* status = key->verdict == network::ServerKeyVerdict::Changed ? @"changed" : @"unknown";
    return [NSError errorWithDomain:@"com.fcxl.network"
                               code:static_cast<NSInteger>(err.code)
                           userInfo:@{
        NSLocalizedDescriptionKey: @(err.message.c_str()) ?: @"",
        FCXLServerKeyStatusKey: status,
        FCXLServerKeyFingerprintKey: @(key->fingerprint.c_str()) ?: @"",
        FCXLServerKeyTypeKey: @(key->key_type.c_str()) ?: @"",
        FCXLServerKeyReasonKey: @(key->reason.c_str()) ?: @"",
    }];
}

static FCXLRemoteEntry* entryFromFileEntry(const common::FileEntry& e) {
    FCXLRemoteEntry* r = [[FCXLRemoteEntry alloc] init];
    r.path = @(e.path.string().c_str());
    r.name = @(e.name.c_str());
    r.fileExtension = @(e.extension.c_str());
    r.size = e.size;
    r.isDirectory = (e.type == common::EntryType::Directory);
    r.isHidden = e.is_hidden;
    r.isSymlink = e.is_symlink;
    r.permissions = @(e.permissions.c_str());
    r.owner = @(e.owner.c_str());
    auto epoch = std::chrono::system_clock::to_time_t(e.date_modified);
    if (epoch > 0) {
        r.modificationDate = [NSDate dateWithTimeIntervalSince1970:epoch];
    }
    return r;
}

// MARK: - FCXLFTPBridge

@implementation FCXLFTPBridge {
    std::unique_ptr<network::FtpClient> _client;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _client = std::make_unique<network::FtpClient>();
    }
    return self;
}

- (BOOL)connectToHost:(NSString *)host
                 port:(uint16_t)port
             username:(NSString *)username
             password:(NSString *)password
               useTLS:(BOOL)useTLS
          passiveMode:(BOOL)passiveMode
      pinnedPublicKey:(NSString *)pinnedPublicKey
              timeout:(int)timeout
                error:(NSError **)error {
    network::ConnectionInfo info;
    info.host = host.UTF8String;
    info.port = port;
    info.username = username.UTF8String ?: "";
    info.password = password.UTF8String ?: "";
    info.use_tls = useTLS;
    info.passive_mode = passiveMode;
    info.pinned_public_key = pinnedPublicKey.UTF8String ?: "";
    info.timeout_seconds = timeout;

    auto result = _client->connect(info);
    if (!result) {
        if (error) *error = makeConnectError(result.error(), _client->last_server_key());
        return NO;
    }
    return YES;
}

- (void)disconnect {
    _client->disconnect();
}

- (BOOL)isConnected {
    return _client->is_connected();
}

- (NSArray<FCXLRemoteEntry *> *)listDirectoryAt:(NSString *)path error:(NSError **)error {
    auto result = _client->list_directory(path.UTF8String);
    if (!result) {
        if (error) *error = makeError(result.error());
        return nil;
    }

    NSMutableArray<FCXLRemoteEntry *> *entries = [NSMutableArray array];
    for (const auto& e : result.value()) {
        [entries addObject:entryFromFileEntry(e)];
    }
    return entries;
}

- (BOOL)downloadFile:(NSString *)remotePath
                  to:(NSString *)localPath
            progress:(BOOL (^)(int64_t, int64_t))progress
               error:(NSError **)error {
    return [self downloadFile:remotePath to:localPath resumeFrom:0
                     progress:progress error:error];
}

- (BOOL)uploadFile:(NSString *)localPath
                to:(NSString *)remotePath
          progress:(BOOL (^)(int64_t, int64_t))progress
             error:(NSError **)error {
    return [self uploadFile:localPath to:remotePath resumeFrom:0
                   progress:progress error:error];
}

- (BOOL)downloadFile:(NSString *)remotePath
                  to:(NSString *)localPath
          resumeFrom:(int64_t)resumeFrom
            progress:(BOOL (^)(int64_t, int64_t))progress
               error:(NSError **)error {
    network::ProgressCallback cb = nullptr;
    if (progress) {
        cb = [progress](int64_t done, int64_t total) -> bool {
            return progress(done, total);
        };
    }

    auto result = _client->download(remotePath.UTF8String, localPath.UTF8String, resumeFrom, cb);
    if (!result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    return YES;
}

- (BOOL)uploadFile:(NSString *)localPath
                to:(NSString *)remotePath
        resumeFrom:(int64_t)resumeFrom
          progress:(BOOL (^)(int64_t, int64_t))progress
             error:(NSError **)error {
    network::ProgressCallback cb = nullptr;
    if (progress) {
        cb = [progress](int64_t done, int64_t total) -> bool {
            return progress(done, total);
        };
    }

    auto result = _client->upload(localPath.UTF8String, remotePath.UTF8String, resumeFrom, cb);
    if (!result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    return YES;
}

- (void)setDownloadSpeedLimit:(int64_t)downloadBytesPerSecond
              uploadSpeedLimit:(int64_t)uploadBytesPerSecond {
    _client->set_speed_limits(downloadBytesPerSecond, uploadBytesPerSecond);
}

- (BOOL)deleteFileAt:(NSString *)remotePath error:(NSError **)error {
    auto result = _client->remove(remotePath.UTF8String);
    if (!result) { if (error) *error = makeError(result.error()); return NO; }
    return YES;
}

- (BOOL)deleteDirectoryAt:(NSString *)remotePath error:(NSError **)error {
    auto result = _client->remove_directory(remotePath.UTF8String);
    if (!result) { if (error) *error = makeError(result.error()); return NO; }
    return YES;
}

- (BOOL)createDirectoryAt:(NSString *)remotePath error:(NSError **)error {
    auto result = _client->create_directory(remotePath.UTF8String);
    if (!result) { if (error) *error = makeError(result.error()); return NO; }
    return YES;
}

- (BOOL)renameFrom:(NSString *)from to:(NSString *)to error:(NSError **)error {
    auto result = _client->rename(from.UTF8String, to.UTF8String);
    if (!result) { if (error) *error = makeError(result.error()); return NO; }
    return YES;
}

@end

// MARK: - FCXLSFTPBridge

@implementation FCXLSFTPBridge {
    std::unique_ptr<network::SftpClient> _client;
}

- (instancetype)init {
    self = [super init];
    if (self) { _client = std::make_unique<network::SftpClient>(); }
    return self;
}

- (BOOL)connectToHost:(NSString *)host port:(uint16_t)port
             username:(NSString *)username password:(NSString *)password
       privateKeyPath:(NSString *)keyPath
       trustedHostKey:(NSString *)trustedHostKey
              timeout:(int)timeout
                error:(NSError **)error {
    network::SftpConnectionInfo info;
    info.host = host.UTF8String;
    info.port = port;
    info.username = username.UTF8String ?: "";
    info.password = password.UTF8String ?: "";
    info.private_key_path = keyPath.UTF8String ?: "";
    info.trusted_host_key = trustedHostKey.UTF8String ?: "";
    info.timeout_seconds = timeout;
    auto result = _client->connect(info);
    if (!result) {
        if (error) *error = makeConnectError(result.error(), _client->last_server_key());
        return NO;
    }
    return YES;
}

- (void)disconnect { _client->disconnect(); }
- (BOOL)isConnected { return _client->is_connected(); }

- (NSArray<FCXLRemoteEntry *> *)listDirectoryAt:(NSString *)path error:(NSError **)error {
    auto result = _client->list_directory(path.UTF8String);
    if (!result) { if (error) *error = makeError(result.error()); return nil; }
    NSMutableArray* entries = [NSMutableArray array];
    for (const auto& e : result.value()) [entries addObject:entryFromFileEntry(e)];
    return entries;
}

- (BOOL)downloadFile:(NSString *)remotePath to:(NSString *)localPath
            progress:(BOOL (^)(int64_t, int64_t))progress error:(NSError **)error {
    return [self downloadFile:remotePath to:localPath resumeFrom:0 progress:progress error:error];
}

- (BOOL)uploadFile:(NSString *)localPath to:(NSString *)remotePath
          progress:(BOOL (^)(int64_t, int64_t))progress error:(NSError **)error {
    return [self uploadFile:localPath to:remotePath resumeFrom:0 progress:progress error:error];
}

- (BOOL)downloadFile:(NSString *)remotePath to:(NSString *)localPath
          resumeFrom:(int64_t)resumeFrom
            progress:(BOOL (^)(int64_t, int64_t))progress error:(NSError **)error {
    network::ProgressCallback cb = nullptr;
    if (progress) cb = [progress](int64_t d, int64_t t) -> bool { return progress(d, t); };
    auto result = _client->download(remotePath.UTF8String, localPath.UTF8String, resumeFrom, cb);
    if (!result) { if (error) *error = makeError(result.error()); return NO; }
    return YES;
}

- (BOOL)uploadFile:(NSString *)localPath to:(NSString *)remotePath
        resumeFrom:(int64_t)resumeFrom
          progress:(BOOL (^)(int64_t, int64_t))progress error:(NSError **)error {
    network::ProgressCallback cb = nullptr;
    if (progress) cb = [progress](int64_t d, int64_t t) -> bool { return progress(d, t); };
    auto result = _client->upload(localPath.UTF8String, remotePath.UTF8String, resumeFrom, cb);
    if (!result) { if (error) *error = makeError(result.error()); return NO; }
    return YES;
}

- (void)setDownloadSpeedLimit:(int64_t)downloadBytesPerSecond
              uploadSpeedLimit:(int64_t)uploadBytesPerSecond {
    _client->set_speed_limits(downloadBytesPerSecond, uploadBytesPerSecond);
}

- (BOOL)deleteFileAt:(NSString *)remotePath error:(NSError **)error {
    auto r = _client->remove(remotePath.UTF8String);
    if (!r) { if (error) *error = makeError(r.error()); return NO; } return YES;
}
- (BOOL)deleteDirectoryAt:(NSString *)remotePath error:(NSError **)error {
    auto r = _client->remove_directory(remotePath.UTF8String);
    if (!r) { if (error) *error = makeError(r.error()); return NO; } return YES;
}
- (BOOL)createDirectoryAt:(NSString *)remotePath error:(NSError **)error {
    auto r = _client->create_directory(remotePath.UTF8String);
    if (!r) { if (error) *error = makeError(r.error()); return NO; } return YES;
}
- (BOOL)renameFrom:(NSString *)from to:(NSString *)to error:(NSError **)error {
    auto r = _client->rename(from.UTF8String, to.UTF8String);
    if (!r) { if (error) *error = makeError(r.error()); return NO; } return YES;
}

@end
