////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMRealm_Private.hpp"

#import "RLMAnalytics.hpp"
#import "RLMArray_Private.hpp"
#import "RLMMigration_Private.h"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMObject_Private.h"
#import "RLMQueryUtil.hpp"
#import "RLMRealmUtil.h"
#import "RLMSchema_Private.h"
#import "RLMUpdateChecker.hpp"
#import "RLMUtil.hpp"

#include <atomic>
#include <sstream>

#include "object_store.hpp"
#include <realm/util/memory_stream.hpp>
#include <realm/commit_log.hpp>
#include <realm/disable_sync_to_disk.hpp>
#include <realm/group_shared.hpp>
#include <realm/lang_bind_helper.hpp>
#include <realm/version.hpp>
#include <realm/sync.hpp>
#include <realm/lang_bind_helper.hpp>

using namespace std;
using namespace realm;
using namespace realm::util;

void RLMDisableSyncToDisk() {
    realm::disable_sync_to_disk();
}

// Notification Token

@interface RLMNotificationToken ()
@property (nonatomic, strong) RLMRealm *realm;
@property (nonatomic, copy) RLMNotificationBlock block;
@end

@implementation RLMNotificationToken
- (void)dealloc
{
    if (_realm || _block) {
        NSLog(@"RLMNotificationToken released without unregistering a notification. You must hold "
              @"on to the RLMNotificationToken returned from addNotificationBlock and call "
              @"removeNotification: when you no longer wish to recieve RLMRealm notifications.");
    }
}
@end

//
// Global encryption key cache and validation
//

static bool shouldForciblyDisableEncryption()
{
    static bool disableEncryption = getenv("REALM_DISABLE_ENCRYPTION");
    return disableEncryption;
}

static NSMutableDictionary *s_keysPerPath = [NSMutableDictionary new];
static NSData *keyForPath(NSString *path) {
    if (shouldForciblyDisableEncryption()) {
        return nil;
    }

    @synchronized (s_keysPerPath) {
        return s_keysPerPath[path];
    }
}

static void clearKeyCache() {
    @synchronized(s_keysPerPath) {
        [s_keysPerPath removeAllObjects];
    }
}

static NSData *validatedKey(NSData *key) {
    if (shouldForciblyDisableEncryption()) {
        return nil;
    }

    if (key) {
        if (key.length != 64) {
            @throw RLMException(@"Encryption key must be exactly 64 bytes long");
        }
        if (RLMIsDebuggerAttached()) {
            @throw RLMException(@"Cannot open an encrypted Realm with a debugger attached to the process");
        }
#if TARGET_OS_WATCH
        @throw RLMException(@"Cannot open an encrypted Realm on watchOS.");
#endif
    }

    return key;
}

static void setKeyForPath(NSData *key, NSString *path) {
    key = validatedKey(key);
    @synchronized (s_keysPerPath) {
        if (key) {
            s_keysPerPath[path] = key;
        }
        else {
            [s_keysPerPath removeObjectForKey:path];
        }
    }
}

//
// Schema version and migration blocks
//
static NSMutableDictionary *s_migrationBlocks = [NSMutableDictionary new];
static NSMutableDictionary *s_schemaVersions = [NSMutableDictionary new];

static NSUInteger schemaVersionForPath(NSString *path) {
    @synchronized(s_migrationBlocks) {
        NSNumber *version = s_schemaVersions[path];
        if (version) {
            return [version unsignedIntegerValue];
        }
        return 0;
    }
}

static RLMMigrationBlock migrationBlockForPath(NSString *path) {
    @synchronized(s_migrationBlocks) {
        return s_migrationBlocks[path];
    }
}

static void clearMigrationCache() {
    @synchronized(s_migrationBlocks) {
        [s_migrationBlocks removeAllObjects];
        [s_schemaVersions removeAllObjects];
    }
}

NSMutableDictionary *s_serverBaseURLS = [NSMutableDictionary dictionary];

// Access to s_syncSessions (referenced NSMapTable object), s_serverConnections
// (referenced NSMapTable object), and s_lastServerConnectionIdent, must be
// synchronized with respect to s_realmsPerPath.

// Maps local path to RLMSyncSession instance
NSMapTable *s_syncSessions = [NSMapTable strongToWeakObjectsMapTable];

// Maps "server:port" to RLMServerConnection instance
NSMapTable *s_serverConnections = [NSMapTable strongToWeakObjectsMapTable];

unsigned long s_lastServerConnectionIdent = 0;

atomic<bool> s_syncLogEverything(false);

// Instances of RLMServerConnection and RLMSyncSession may be created by any
// thread, but all instance methods must be called by the main thread, except
// backgroundTask and backgroundApplyChangeset in RLMSyncSession which are
// called internally from a background thread.

@interface RLMOutputMessage : NSObject
@property (nonatomic) NSString *head;
@property (nonatomic) NSData *body; // May be nil
@end

@interface RLMServerConnection : NSObject <NSStreamDelegate>
@property (readonly, nonatomic) unsigned long ident; // Used only for logging
@property (readonly, nonatomic) BOOL isOpen;
@end

@interface RLMSyncSession : NSObject
@property (readonly, nonatomic) RLMServerConnection *connection;
@property (readonly, nonatomic) NSNumber *sessionIdent;
@property (nonatomic) uint_fast64_t serverFileIdent;
@property (nonatomic) uint_fast64_t clientFileIdent;
@property (readonly, nonatomic) NSString *serverPath;
@property (readonly, nonatomic) NSString *clientPath;
- (void)connectionIsOpen;
- (void)connectionIsOpenAndSessionHasFileIdent;
- (void)connectionIsClosed;
- (void)handleAllocMessageWithServerFileIdent:(uint_fast64_t)serverFileIdent
                              clientFileIdent:(uint_fast64_t)clientFileIdent;
- (void)handleChangesetMessageWithServerVersion:(Replication::version_type)serverVersion
                                  clientVersion:(Replication::version_type)clientVersion
                                originTimestamp:(uint_fast64_t)originTimestamp
                                originFileIdent:(uint_fast64_t)originFileIdent
                                           data:(NSData *)data;
- (void)handleAcceptMessageWithServerVersion:(Replication::version_type)serverVersion
                               clientVersion:(Replication::version_type)clientVersion;
@end


@implementation RLMOutputMessage {
    void (^_completionHandler)();
}

- (instancetype)init {
    self = [super init];
    if (self)
        _completionHandler = nil;
    return self;
}

- (void (^)())completionHandler {
    return _completionHandler;
}

- (void)setCompletionHandler:(void (^)())block {
    _completionHandler = block;
}

@end


@implementation RLMServerConnection {
    BOOL _isOpen;

    NSString *_address;
    NSNumber *_port;

    NSRunLoop *_runLoop;

    NSInputStream  *_inputStream;
    NSOutputStream *_outputStream;

    BOOL _inputIsHead;
    size_t _inputBufferSize;
    unique_ptr<char[]> _inputBuffer;

    size_t _headBufferSize;
    unique_ptr<char[]> _headBuffer;
    char *_headBufferCurr;

    size_t _messageBodySize;
    NSMutableData *_messageBodyBuffer;
    char *_messageBodyCurr;
    void (^_messageHandler)();

    NSMutableArray *_outputQueue; // Of RLMOutputMessage instances
    NSData *_currentOutputChunk;
    NSData *_nextOutputChunk;
    void (^_outputCompletionHandler)();
    const char *_currentOutputBegin;
    const char *_currentOutputEnd;

    unsigned _lastSessionIdent;

    // Maps session identifiers to an RLMSyncSession instances. A session
    // identifier is a locally assigned integer that uniquely identifies the
    // RLMSyncSession instance within a particular server connection.
    NSMapTable *_sessions;
}


- (instancetype)initWithIdent:(unsigned long)ident address:(NSString *)address
                         port:(NSNumber *)port {
    self = [super init];
    if (self) {
        _ident = ident;
        _isOpen = NO;

        _address = address;
        _port = port ? port : [NSNumber numberWithInt:7800];

        _runLoop = nil;

        _inputBufferSize = 1024;
        _inputBuffer = make_unique<char[]>(_inputBufferSize);

        _headBufferSize = 256;
        _headBuffer = make_unique<char[]>(_headBufferSize);

        _currentOutputChunk = nil;
        _nextOutputChunk = nil;
        _outputCompletionHandler = nil;

        _lastSessionIdent = 0;
        _sessions = [NSMapTable strongToWeakObjectsMapTable];
    }
    return self;
}


- (unsigned)newSessionIdent
{
    return ++_lastSessionIdent;
}


- (void)mainThreadInit {
    // Called by main thread
    if (_runLoop)
        return;
    _runLoop = [NSRunLoop currentRunLoop];

    [self open];
}


- (void)open {
    if (_isOpen)
        return;

    NSLog(@"RealmSync: Connection[%lu]: Opening connection to %@:%@", _ident, _address, _port);

    CFAllocatorRef defaultAllocator = 0;
    CFStringRef address2 = (__bridge CFStringRef)_address;
    UInt32 port2 = UInt32(_port.unsignedLongValue);
    CFReadStreamRef  readStream  = 0;
    CFWriteStreamRef writeStream = 0;
    CFStreamCreatePairWithSocketToHost(defaultAllocator, address2, port2,
                                       &readStream, &writeStream);
    NSInputStream  *inputStream  = (__bridge_transfer NSInputStream  *)readStream;
    NSOutputStream *outputStream = (__bridge_transfer NSOutputStream *)writeStream;

    [inputStream setDelegate:self];
    [outputStream setDelegate:self];

    [inputStream scheduleInRunLoop:_runLoop forMode:NSDefaultRunLoopMode];
    [inputStream open];
    [outputStream open];

    _inputStream  = inputStream;
    _outputStream = outputStream;

    _inputIsHead = YES;
    _headBufferCurr = _headBuffer.get();

    _outputQueue = [NSMutableArray array];

    _isOpen = YES;

    [self sendIdentMessage];

    for (NSNumber *sessionIdent in _sessions) {
        RLMSyncSession *session = [_sessions objectForKey:sessionIdent];
        [session connectionIsOpen];
    }
}


- (void)closeAndTryToReconnectLater {
    if (!_isOpen)
        return;

    [_inputStream close];
    [_outputStream close];

    _inputStream  = nil;
    _outputStream = nil;

    _outputQueue = nil;
    _currentOutputChunk = nil;
    _nextOutputChunk = nil;
    _outputCompletionHandler = nil;

    _isOpen = NO;

    for (NSNumber *sessionIdent in _sessions) {
        RLMSyncSession *session = [_sessions objectForKey:sessionIdent];
        [session connectionIsClosed];
    }

    NSTimeInterval reconnectDelay = 5;

    NSLog(@"RealmSync: Connection[%lu]: Closed (will try to reconnect in %g seconds)",
          _ident, double(reconnectDelay));

    [self performSelector:@selector(open) withObject:nil afterDelay:reconnectDelay];
}


- (void)addSession:(RLMSyncSession *)session {
    [_sessions setObject:session forKey:session.sessionIdent];
    if (_isOpen)
        [session connectionIsOpen];
}


- (void)sendIdentMessage {
    // FIXME: These need to be set correctly (tentative:
    // `applicationIdent` is a unique application identifier registered with
    // Realm and `userIdent` could for example be the concattenation of a user
    // name and a password).
    NSData *applicationIdent = [@"dummy_app"  dataUsingEncoding:NSUTF8StringEncoding];
    NSData *userIdent        = [@"dummy_user" dataUsingEncoding:NSUTF8StringEncoding];

    NSMutableData *body = [applicationIdent mutableCopy];
    [body appendData:userIdent];

    uint_fast64_t protocolVersion = 1;
    size_t applicationIdentSize = size_t(applicationIdent.length);
    size_t userIdentSize        = size_t(userIdent.length);
    typedef unsigned long      ulong;
    typedef unsigned long long ulonglong;
    RLMOutputMessage *msg = [[RLMOutputMessage alloc] init];
    msg.body = body;
    msg.head = [NSString stringWithFormat:@"ident %llu %lu %lu\n", ulonglong(protocolVersion),
                         ulong(applicationIdentSize), ulong(userIdentSize)];
    [self enqueueOutputMessage:msg];
    NSLog(@"RealmSync: Connection[%lu]: Sending: Application and user identities", _ident);
}


- (void)sendAllocMessageWithSessionIdent:(NSNumber *)sessionIdent
                              serverPath:(NSString *)serverPath {
    RLMOutputMessage *msg = [[RLMOutputMessage alloc] init];
    typedef unsigned long ulong;
    msg.body = [serverPath dataUsingEncoding:NSUTF8StringEncoding];
    msg.head = [NSString stringWithFormat:@"alloc %@ %lu\n", sessionIdent, ulong(msg.body.length)];
    [self enqueueOutputMessage:msg];
    NSLog(@"RealmSync: Connection[%lu]: Session[%@]: Sending: Allocate unique identifier pair for "
          "remote Realm '%@'", _ident, sessionIdent, serverPath);
}


- (void)sendBindMessageWithSessionIdent:(NSNumber *)sessionIdent
                              serverFileIdent:(uint_fast64_t)serverFileIdent
                              clientFileIdent:(uint_fast64_t)clientFileIdent
                          serverVersion:(Replication::version_type)serverVersion
                          clientVersion:(Replication::version_type)clientVersion
                             serverPath:(NSString *)serverPath
                             clientPath:(NSString *)clientPath {
    typedef unsigned long      ulong;
    typedef unsigned long long ulonglong;
    RLMOutputMessage *msg = [[RLMOutputMessage alloc] init];
    msg.body = [serverPath dataUsingEncoding:NSUTF8StringEncoding];
    msg.head = [NSString stringWithFormat:@"bind %@ %llu %llu %llu %llu %lu\n", sessionIdent,
                         ulonglong(serverFileIdent), ulonglong(clientFileIdent),
                         ulonglong(serverVersion), ulonglong(clientVersion),
                         ulong(msg.body.length)];
    [self enqueueOutputMessage:msg];
    NSLog(@"RealmSync: Connection[%lu]: Sessions[%@]: Sending: Bind local Realm '%@' (%llu) "
          "to remote Realm '%@' (%llu) continuing synchronization from server version %llu, "
          "whose last integrated client version is %llu", _ident, sessionIdent, clientPath,
          ulonglong(clientFileIdent), serverPath, ulonglong(serverFileIdent),
          ulonglong(serverVersion), ulonglong(clientVersion));
}


- (void)sendUnbindMessageWithSessionIdent:(NSNumber *)sessionIdent {
    RLMOutputMessage *msg = [[RLMOutputMessage alloc] init];
    msg.head = [NSString stringWithFormat:@"unbind %@\n", sessionIdent];
    [self enqueueOutputMessage:msg];
    NSLog(@"RealmSync: Connection[%lu]: Session[%@]: Sending: Unbind", _ident, sessionIdent);
}


- (void)enqueueOutputMessage:(RLMOutputMessage *)msg {
    [_outputQueue addObject:msg];
    if (_isOpen && !_currentOutputChunk) {
        [self resumeOutput];
        [_outputStream scheduleInRunLoop:_runLoop forMode:NSDefaultRunLoopMode];
    }
}


- (BOOL)resumeOutput {
    if (_nextOutputChunk) {
        _currentOutputChunk = _nextOutputChunk;
        _nextOutputChunk = nil;
    }
    else {
        if (_outputCompletionHandler) {
            void (^completionHandler)();
            completionHandler = _outputCompletionHandler;
            _outputCompletionHandler = nil;
            // This handler is allowed to enqueue new output messages
            completionHandler();
        }
        RLMOutputMessage *msg = _outputQueue.firstObject;
        if (!msg)
            return NO;
        _currentOutputChunk = [msg.head dataUsingEncoding:NSUTF8StringEncoding];
        _nextOutputChunk = msg.body;
        if (_nextOutputChunk.length == 0)
            _nextOutputChunk = nil;
        _outputCompletionHandler = msg.completionHandler;
        [_outputQueue removeObjectAtIndex:0];
    }
    _currentOutputBegin = static_cast<const char*>(_currentOutputChunk.bytes);
    _currentOutputEnd   = _currentOutputBegin + _currentOutputChunk.length;
    return YES;
}


- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
    switch (eventCode) {
        case NSStreamEventHasBytesAvailable: {
            if (stream != _inputStream)
                return;
            uint8_t *buffer = reinterpret_cast<uint8_t *>(_inputBuffer.get());
            NSUInteger length = _inputBufferSize;
            NSInteger n = [_inputStream read:buffer maxLength:length];
            if (n < 0) {
                NSLog(@"RealmSync: Connection[%lu]: Error reading from socket: %@",
                      _ident, _inputStream.streamError);
                [self closeAndTryToReconnectLater];
                return;
            }
            if (n == 0)
                goto end_of_input;
            char *headBufferBegin = _headBuffer.get();
            char *headBufferEnd = headBufferBegin + _headBufferSize;
            const char *inputBegin = _inputBuffer.get();
            const char *inputEnd = inputBegin + n;
            if (!_inputIsHead)
                goto body;
            for (;;) {
                // Message head
                {
                    size_t sourceAvail = inputEnd - inputBegin;
                    size_t destAvail = headBufferEnd - _headBufferCurr;
                    size_t avail = min(sourceAvail, destAvail);
                    const char *i = find(inputBegin, inputBegin + avail, '\n');
                    _headBufferCurr = copy(inputBegin, i, _headBufferCurr);
                    if (_headBufferCurr == headBufferEnd) {
                        NSLog(@"RealmSync: Connection[%lu]: Message head too big", _ident);
                        [self closeAndTryToReconnectLater];
                        return;
                    }
                    inputBegin = i;
                    if (inputBegin == inputEnd)
                        break;
                    ++inputBegin; // Discard newline from input
                    _inputIsHead = NO;

                    MemoryInputStream parser;
                    parser.set_buffer(headBufferBegin, _headBufferCurr);
                    _headBufferCurr = headBufferBegin;
                    parser.unsetf(std::ios_base::skipws);

                    string message_type;
                    parser >> message_type;

                    _messageHandler = nil;
                    __weak RLMServerConnection *weakSelf = self;
                    if (message_type == "changeset") {
                        // A new foreign changeset is available for download
                        unsigned sessionIdent = 0;
                        Replication::version_type serverVersion = 0;
                        Replication::version_type clientVersion = 0;
                        uint_fast64_t originTimestamp = 0;
                        uint_fast64_t originFileIdent = 0;
                        size_t changesetSize = 0;
                        char sp1, sp2, sp3, sp4, sp5, sp6;
                        parser >> sp1 >> sessionIdent >> sp2 >> serverVersion >> sp3 >>
                            clientVersion >> sp4 >> originTimestamp >> sp5 >>
                            originFileIdent >> sp6 >> changesetSize;
                        bool good = parser && parser.eof() && sp1 == ' ' && sp2 == ' ' &&
                            sp3 == ' ' && sp4 == ' ' && sp5 == ' ' && sp6 == ' ';
                        if (!good) {
                            NSLog(@"RealmSync: Connection[%lu]: Bad 'changeset' message "
                                  "from server", _ident);
                            [self closeAndTryToReconnectLater];
                            return;
                        }
                        _messageBodySize = changesetSize;
                        _messageHandler = ^{
                            NSNumber *sessionIdent2 = [NSNumber numberWithUnsignedInteger:sessionIdent];
                            [weakSelf handleChangesetMessageWithSessionIdent:sessionIdent2
                                                               serverVersion:serverVersion
                                                               clientVersion:clientVersion
                                                             originTimestamp:originTimestamp
                                                             originFileIdent:originFileIdent];
                        };
                    }
                    else if (message_type == "accept") {
                        // Server accepts a previously uploaded changeset
                        unsigned sessionIdent = 0;
                        Replication::version_type serverVersion = 0;
                        Replication::version_type clientVersion = 0;
                        char sp1, sp2, sp3;
                        parser >> sp1 >> sessionIdent >> sp2 >> serverVersion >> sp3 >>
                            clientVersion;
                        bool good = parser && parser.eof() && sp1 == ' ' && sp2 == ' ' &&
                            sp3 == ' ';
                        if (!good) {
                            NSLog(@"RealmSync: Connection[%lu]: Bad 'accept' message "
                                  "from server", _ident);
                            [self closeAndTryToReconnectLater];
                            return;
                        }
                        NSNumber *sessionIdent2 = [NSNumber numberWithUnsignedInteger:sessionIdent];
                        [self handleAcceptMessageWithSessionIdent:sessionIdent2
                                                    serverVersion:serverVersion
                                                    clientVersion:clientVersion];
                    }
                    else if (message_type == "alloc") {
                        // New unique file identifier pair from server.
                        unsigned sessionIdent = 0;
                        uint_fast64_t serverFileIdent = 0, clientFileIdent = 0;
                        char sp1, sp2, sp3;
                        parser >> sp1 >> sessionIdent >> sp2 >> serverFileIdent >> sp3 >>
                            clientFileIdent;
                        bool good = parser && parser.eof() && sp1 == ' ' && sp2 == ' ' &&
                            sp3 == ' ';
                        if (!good) {
                            NSLog(@"RealmSync: Connection[%lu]: Bad 'alloc' message "
                                  "from server", _ident);
                            [self closeAndTryToReconnectLater];
                            return;
                        }
                        NSNumber *sessionIdent2 = [NSNumber numberWithUnsignedInteger:sessionIdent];
                        [self handleAllocMessageWithSessionIdent:sessionIdent2
                                                 serverFileIdent:serverFileIdent
                                                 clientFileIdent:clientFileIdent];
                    }
                    else {
                        NSLog(@"RealmSync: Connection[%lu]: Bad message from server", _ident);
                        [self closeAndTryToReconnectLater];
                        return;
                    }
                }

                // Message body
                if (_messageHandler) {
                    _messageBodyBuffer = [NSMutableData dataWithLength:_messageBodySize];
                    _messageBodyCurr = static_cast<char*>(_messageBodyBuffer.mutableBytes);
                  body:
                    char *messageBodyBegin = static_cast<char*>(_messageBodyBuffer.mutableBytes);
                    char *messageBodyEnd = messageBodyBegin + _messageBodySize;
                    size_t sourceAvail = inputEnd - inputBegin;
                    size_t destAvail = messageBodyEnd - _messageBodyCurr;
                    size_t avail = min(sourceAvail, destAvail);
                    const char *i = inputBegin + avail;
                    _messageBodyCurr = copy(inputBegin, i, _messageBodyCurr);
                    inputBegin = i;
                    if (_messageBodyCurr != messageBodyEnd) {
                        REALM_ASSERT(inputBegin == inputEnd);
                        break;
                    }
                    void (^messageHandler)();
                    messageHandler = _messageHandler;
                    _messageHandler = nil;
                    messageHandler();
                    if (!_isOpen)
                        return;
                }
                _inputIsHead = YES;
            }
            break;
        }
        case NSStreamEventHasSpaceAvailable: {
            if (stream != _outputStream)
                return;
            REALM_ASSERT(_currentOutputChunk);
            const uint8_t *buffer = reinterpret_cast<const uint8_t *>(_currentOutputBegin);
            NSUInteger length = _currentOutputEnd - _currentOutputBegin;
            NSInteger n = [_outputStream write:buffer maxLength:length];
            if (n < 0) {
                NSLog(@"RealmSync: Connection[%lu]: Error writing to socket: %@",
                      _ident, _outputStream.streamError);
                [self closeAndTryToReconnectLater];
                return;
            }
            _currentOutputBegin += n;
            if (_currentOutputBegin == _currentOutputEnd) {
                BOOL more = [self resumeOutput];
                if (!more) {
                    _currentOutputChunk = 0;
                    [_outputStream removeFromRunLoop:_runLoop forMode:NSDefaultRunLoopMode];
                }
            }
            break;
        }
        case NSStreamEventEndEncountered: {
            if (stream != _inputStream && stream != _outputStream)
                return;
          end_of_input:
            NSLog(@"RealmSync: Connection[%lu]: Server closed connection", _ident);
            [self closeAndTryToReconnectLater];
            return;
        }
        case NSStreamEventErrorOccurred: {
            if (stream != _inputStream && stream != _outputStream)
                return;
            NSLog(@"RealmSync: Connection[%lu]: Socket error: %@", _ident, stream.streamError);
            [self closeAndTryToReconnectLater];
            return;
        }
    }
}


- (void)handleAllocMessageWithSessionIdent:(NSNumber *)sessionIdent
                           serverFileIdent:(uint_fast64_t)serverFileIdent
                           clientFileIdent:(uint_fast64_t)clientFileIdent {
    typedef unsigned long long ulonglong;
    NSLog(@"RealmSync: Connection[%lu]: Session[%@]: Received: New unique Realm identifier pair "
          "is (%llu, %llu)", _ident, sessionIdent, ulonglong(serverFileIdent),
          ulonglong(clientFileIdent));

    RLMSyncSession *session = [_sessions objectForKey:sessionIdent];
    if (!session)
        return; // This session no longer exists

    [session handleAllocMessageWithServerFileIdent:serverFileIdent
                                   clientFileIdent:clientFileIdent];
}


- (void)handleChangesetMessageWithSessionIdent:(NSNumber *)sessionIdent
                                 serverVersion:(Replication::version_type)serverVersion
                                 clientVersion:(Replication::version_type)clientVersion
                               originTimestamp:(uint_fast64_t)originTimestamp
                               originFileIdent:(uint_fast64_t)originFileIdent {
    if (s_syncLogEverything) {
        typedef unsigned long long ulonglong;
        NSLog(@"RealmSync: Connection[%lu]: Session[%@]: Received: Changeset %llu -> %llu "
              "of size %lu with origin timestamp %llu and origin client Realm identifier %llu "
              "(last integrated client version is %llu)", _ident, sessionIdent,
              ulonglong(serverVersion-1), ulonglong(serverVersion), (unsigned long)_messageBodyBuffer.length,
              ulonglong(originTimestamp), ulonglong(originFileIdent), ulonglong(clientVersion));
    }

    RLMSyncSession *session = [_sessions objectForKey:sessionIdent];
    if (!session)
        return; // This session no longer exists

    NSData *data = _messageBodyBuffer;
    _messageBodyBuffer = nil;

    [session handleChangesetMessageWithServerVersion:serverVersion
                                       clientVersion:clientVersion
                                     originTimestamp:originTimestamp
                                     originFileIdent:originFileIdent
                                                data:data];
}


- (void)handleAcceptMessageWithSessionIdent:(NSNumber *)sessionIdent
                              serverVersion:(Replication::version_type)serverVersion
                              clientVersion:(Replication::version_type)clientVersion {
    if (s_syncLogEverything) {
        typedef unsigned long long ulonglong;
        NSLog(@"RealmSync: Connection[%lu]: Session[%@]: Received: Accept changeset %llu -> %llu, "
              "producing server version %llu", _ident, sessionIdent,
              ulonglong(clientVersion-1), ulonglong(clientVersion), ulonglong(serverVersion));
    }

    RLMSyncSession *session = [_sessions objectForKey:sessionIdent];
    if (!session)
        return; // This session no longer exists

    [session handleAcceptMessageWithServerVersion:serverVersion clientVersion:clientVersion];
}

@end


@implementation RLMSyncSession {
    unique_ptr<SharedGroup>   _sharedGroup;
    unique_ptr<ClientHistory> _history;

    unique_ptr<SharedGroup>   _backgroundSharedGroup; // For background thread
    unique_ptr<ClientHistory> _backgroundHistory;     // For background thread
    unique_ptr<Transformer>   _backgroundTransformer; // For background thread

    Replication::version_type _latestVersionAvailable;
    Replication::version_type _latestVersionUploaded;
    Replication::version_type _syncProgressServerVersion;
    Replication::version_type _syncProgressClientVersion;
    Replication::version_type _serverVersionThreshold;
    BOOL _uploadInProgress;

    NSOperationQueue *_backgroundOperationQueue;
}


- (instancetype)initWithConnection:(RLMServerConnection *)connection
                        serverPath:(NSString *)serverPath
                        clientPath:(NSString *)clientPath {
    self = [super init];
    if (self) {
        _connection = connection;
        _serverFileIdent = 0; // Assigned when `_clientFileIdent` is assigned
        _clientFileIdent = 0; // Zero means unassigned
        _serverPath = serverPath;
        _clientPath = clientPath;
        _sessionIdent = [NSNumber numberWithUnsignedInteger:[connection newSessionIdent]];

        SharedGroup::DurabilityLevel durability = SharedGroup::durability_Full;
        _history = realm::make_client_sync_history(clientPath.UTF8String);
        _sharedGroup = make_unique<SharedGroup>(*_history, durability);
        _backgroundHistory = realm::make_client_sync_history(clientPath.UTF8String);
        _backgroundSharedGroup = make_unique<SharedGroup>(*_backgroundHistory, durability);
        _backgroundTransformer = realm::make_sync_demo(false, *_backgroundHistory);
        _backgroundOperationQueue = [[NSOperationQueue alloc] init];
        _backgroundOperationQueue.name = @"io.realm.sync";
        _backgroundOperationQueue.maxConcurrentOperationCount = 1;
    }
    return self;
}


- (void)mainThreadInit {
    // Called by main thread
    uint_fast64_t serverFileIdent, clientFileIdent;
    if (_history->get_file_ident_pair(serverFileIdent, clientFileIdent)) {
        _serverFileIdent = serverFileIdent;
        _clientFileIdent = clientFileIdent;
        _backgroundTransformer->set_local_client_file_ident(clientFileIdent);
    }

    _history->get_sync_progress(_syncProgressServerVersion, _syncProgressClientVersion);

    _latestVersionAvailable = LangBindHelper::get_current_version(*_sharedGroup);
    REALM_ASSERT(_latestVersionAvailable >= 1);
    REALM_ASSERT(_latestVersionAvailable >= _syncProgressClientVersion);

    // Due to the nature of the protocol, it is possible that the server sends a
    // changeset that was previously sent, and already integrated locally. To be
    // able to detect this situation, we need to know the latest server version
    // that is already integrated, so that we can skip those changesets. We have
    // `_syncProgressServerVersion`, but it is not guaranteed to be completely
    // up to date with what is actually in the history. For that reason, we have
    // to manually search a portion of the history.
    //
    // FIXME: Consider whether this can be done in the same way, and at the same
    // time as latest_local_time_seen and latest_remote_time_seen are managed
    // inside the CommitLogs class.
    _serverVersionThreshold = _syncProgressServerVersion;
    {
        HistoryEntry historyEntry;
        History::version_type version = _latestVersionAvailable;
        if (version == 1)
            version = 0;
        while (version > _syncProgressClientVersion) {
            History::version_type prevVersion = _history->get_history_entry(version, historyEntry);
            BOOL isForeign = historyEntry.origin_client_file_ident != 0;
            if (isForeign) {
                _serverVersionThreshold = historyEntry.remote_version;
                break;
            }
            version = prevVersion;
        }
    }

/*
    NSLog(@"_latestVersionAvailable = %llu", (unsigned long long)(_latestVersionAvailable));
    NSLog(@"_latestVersionUploaded = %llu", (unsigned long long)(_latestVersionUploaded));
    NSLog(@"_syncProgressServerVersion = %llu", (unsigned long long)(_syncProgressServerVersion));
    NSLog(@"_syncProgressClientVersion = %llu", (unsigned long long)(_syncProgressClientVersion));
    NSLog(@"_serverVersionThreshold = %llu", (unsigned long long)(_serverVersionThreshold));
*/

    [_connection mainThreadInit];
    [_connection addSession:self];
}


- (void)refreshLatestVersionAvailable {
    _latestVersionAvailable = LangBindHelper::get_current_version(*_sharedGroup);
    if (_connection.isOpen && _clientFileIdent != 0)
        [self resumeUpload];
}


- (void)connectionIsOpen {
    if (_clientFileIdent != 0) {
        [self connectionIsOpenAndSessionHasFileIdent];
    }
    else {
        [_connection sendAllocMessageWithSessionIdent:_sessionIdent
                                           serverPath:_serverPath];
    }
}


- (void)connectionIsOpenAndSessionHasFileIdent {
    _latestVersionUploaded = std::max<History::version_type>(1, _syncProgressClientVersion);
    if (_latestVersionUploaded > _latestVersionAvailable) // Transiently possible (FIXME: Or is it?)
        _latestVersionUploaded = _latestVersionAvailable;
    [_connection sendBindMessageWithSessionIdent:_sessionIdent
                                       serverFileIdent:_serverFileIdent
                                       clientFileIdent:_clientFileIdent
                                   serverVersion:_syncProgressServerVersion
                                   clientVersion:_syncProgressClientVersion
                                      serverPath:_serverPath
                                      clientPath:_clientPath];
    [self resumeUpload];
}


- (void)connectionIsClosed {
    _uploadInProgress = NO;
}


- (void)resumeUpload {
    REALM_ASSERT(_connection.isOpen && _clientFileIdent != 0);
    if (_uploadInProgress)
        return;
    _uploadInProgress = YES;

    // Fetch and copy the next changeset, and produce an output message from it.
    // Set the completionHandler to a block that calls resumeUpload.
    HistoryEntry::version_type uploadVersion;
    HistoryEntry historyEntry;
    for (;;) {
        REALM_ASSERT(_latestVersionUploaded <= _latestVersionAvailable);
        if (_latestVersionUploaded == _latestVersionAvailable) {
            _uploadInProgress = NO;
            return;
        }
        uploadVersion = _latestVersionUploaded + 1;
        _history->get_history_entry(uploadVersion, historyEntry);
        // Skip changesets that were downloaded from the server
        BOOL isForeign = historyEntry.origin_client_file_ident != 0;
        if (!isForeign)
            break;
        _latestVersionUploaded = uploadVersion;
    }
    using ulonglong = unsigned long long;
    // `serverVersion` is the last server version that has been integrated into
    // `uploadVersion`.
    ulonglong serverVersion = historyEntry.remote_version;
    RLMOutputMessage *msg = [[RLMOutputMessage alloc] init];
    msg.body = [NSData dataWithBytes:historyEntry.changeset.data()
                              length:historyEntry.changeset.size()]; // Full copy
    msg.head = [NSString stringWithFormat:@"changeset %@ %llu %llu %llu %lu\n", _sessionIdent,
                         ulonglong(uploadVersion), ulonglong(serverVersion),
                         ulonglong(historyEntry.origin_timestamp), (unsigned long)msg.body.length];
    if (s_syncLogEverything) {
        NSLog(@"RealmSync: Connection[%lu]: Session[%@]: Sending: Changeset %llu -> %llu "
              "of size %lu with timestamp %llu (last integrated server version is %llu)",
              _connection.ident, _sessionIdent, ulonglong(uploadVersion-1),
              ulonglong(uploadVersion), (unsigned long)msg.body.length, ulonglong(historyEntry.origin_timestamp),
              serverVersion);
    }
    __weak RLMSyncSession *weakSelf = self;
    [msg setCompletionHandler:^{
            [weakSelf uploadCompletedWithVersion:uploadVersion];
        }];
    [_connection enqueueOutputMessage:msg];
}


- (void)uploadCompletedWithVersion:(Replication::version_type)version {
    REALM_ASSERT(version <= _latestVersionUploaded+1);
    _uploadInProgress = NO;
    if (_latestVersionUploaded < version)
        _latestVersionUploaded = version;
    if (_connection.isOpen)
        [self resumeUpload];
}


- (void)handleAllocMessageWithServerFileIdent:(uint_fast64_t)serverFileIdent
                              clientFileIdent:(uint_fast64_t)clientFileIdent {
    _history->set_file_ident_pair(serverFileIdent, clientFileIdent); // Save in persistent storage
    // FIXME: Describe what (if anything) prevents a race condition here, as a
    // naive analysis would suggest that the background thread could be
    // accessing _backgroundHistory concurrently. It would be tempting to
    // conclude that a race is not possible, because the background thread must
    // not attempt to transform anything before the file identifier is
    // known. Note that it cannot be assumed the there will be no spurious
    // 'alloc' messages received.
    _backgroundTransformer->set_local_client_file_ident(clientFileIdent);
    _serverFileIdent = serverFileIdent;
    _clientFileIdent = clientFileIdent;
    if (_connection.isOpen)
        [self connectionIsOpenAndSessionHasFileIdent];
}


- (void)handleChangesetMessageWithServerVersion:(Replication::version_type)serverVersion
                                  clientVersion:(Replication::version_type)clientVersion
                                originTimestamp:(uint_fast64_t)originTimestamp
                                originFileIdent:(uint_fast64_t)originFileIdent
                                           data:(NSData *)data {
    // We cannot save the synchronization progress marker (`serverVersion`,
    // `clientVersion`) to persistent storage until the changeset is actually
    // integrated locally, but that means it will be delayed by two context
    // switches, i.e., first by a switch to the background thread, and then by a
    // switch back to the main thread, and in each of these switches there is a
    // risk of termination of the flow of this information due to a severed weak
    // reference, which presumably would be due to the termination of the
    // synchronization session, but not necessarily in connection with the
    // termination of the application.
    //
    // Additionally, we want to be able to make a proper monotony check on
    // `serverVersion` and `clientVersion` before having the background thread
    // attempting to apply the changeset, and to do that, we must both check and
    // update `_syncProgressServerVersion` and `_syncProgressClientVersion`
    // right here in the main thread.
    //
    // Note: The server version must increase, since it is the number of a new
    // server version. The client version, however, can only be increased by an
    // 'accept' message, so it must remain unchanged here.
    bool good_versions = serverVersion > _syncProgressServerVersion &&
        clientVersion == _syncProgressClientVersion;
    if (!good_versions) {
        NSLog(@"RealmSync: Connection[%lu]: Session[%@]: ERROR: Bad server or client version "
              "in 'changeset' message", _connection.ident, _sessionIdent);
        [_connection closeAndTryToReconnectLater];
        return;

    }
    _syncProgressServerVersion = serverVersion;

    // Skip changesets that were already integrated during an earlier session,
    // but still attempt to save a new synchronization progress marker to
    // persistent storage.
    if (serverVersion <= _serverVersionThreshold) {
        if (s_syncLogEverything) {
            using ulonglong = unsigned long long;
            NSLog(@"RealmSync: Connection[%lu]: Session[%@]: Ignoring previously integrated "
                  "changeset (threshold is %llu)", _connection.ident, _sessionIdent,
                  ulonglong(_serverVersionThreshold));
        }
        [self addBackgroundTaskWithServerVersion:serverVersion
                                   clientVersion:clientVersion
                                 originTimestamp:0
                                 originFileIdent:0
                                            data:nil];
        return;
    }

    // FIXME: Consider whether we should attempt to apply small changsesets
    // immediately on the main thread (right here) if auto-refresh is enabled,
    // `_backgroundOperationQueue` is empty, and a try-lock on the
    // write-transaction mutex succeeds. This might be an effective way of
    // reducing latency due to context switches.

    [self addBackgroundTaskWithServerVersion:serverVersion
                               clientVersion:clientVersion
                             originTimestamp:originTimestamp
                             originFileIdent:originFileIdent
                                        data:data];
}


- (void)handleAcceptMessageWithServerVersion:(Replication::version_type)serverVersion
                               clientVersion:(Replication::version_type)clientVersion {
    // As with 'changeset' messages, we need to update the synchronization
    // progress marker.
    //
    // FIXME: Properly explain the three roles of the synchronization progress
    // marker (syncronization restart point, history upload window specifier,
    // and history merge window specifier), and the intricate interplay between
    // them.
    //
    // Note: The server version must increase, since it is the number of a new
    // server version. The client version must also increase, because it
    // specifies the last integrated client version, and an 'accept' message
    // implies that a new client version was integrated.
    bool good_versions = serverVersion > _syncProgressServerVersion &&
        clientVersion > _syncProgressClientVersion &&
        clientVersion <= _latestVersionUploaded;
    if (!good_versions) {
        NSLog(@"RealmSync: Connection[%lu]: Session[%@]: ERROR: Bad server or client version "
              "in 'accept' message", _connection.ident, _sessionIdent);
        [_connection closeAndTryToReconnectLater];
        return;

    }
    _syncProgressServerVersion = serverVersion;
    _syncProgressClientVersion = clientVersion;

    // The order in which updated synchronization progress markers are saved to
    // persistent storage must be the same order in with the are received from
    // the server either via a 'changeset' message or an 'accept' message.
    [self addBackgroundTaskWithServerVersion:serverVersion
                               clientVersion:clientVersion
                             originTimestamp:0
                             originFileIdent:0
                                        data:nil];
}


- (void)addBackgroundTaskWithServerVersion:(Replication::version_type)serverVersion
                             clientVersion:(Replication::version_type)clientVersion
                           originTimestamp:(uint_fast64_t)originTimestamp
                           originFileIdent:(uint_fast64_t)originFileIdent
                                      data:(NSData *)data {
    __weak RLMSyncSession *weakSelf = self;
    [_backgroundOperationQueue addOperationWithBlock:^{
            [weakSelf backgroundTaskWithServerVersion:serverVersion
                                        clientVersion:clientVersion
                                      originTimestamp:originTimestamp
                                      originFileIdent:originFileIdent
                                                 data:data];
        }];
}


- (void)backgroundTaskWithServerVersion:(Replication::version_type)serverVersion
                          clientVersion:(Replication::version_type)clientVersion
                        originTimestamp:(uint_fast64_t)originTimestamp
                        originFileIdent:(uint_fast64_t)originFileIdent
                                   data:(NSData *)data {
    if (data)
        [self backgroundApplyChangesetWithServerVersion:serverVersion
                                          clientVersion:clientVersion
                                        originTimestamp:originTimestamp
                                        originFileIdent:originFileIdent
                                                   data:data];

    __weak RLMSyncSession *weakSelf = self;
    NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
    [mainQueue addOperationWithBlock:^{
            [weakSelf updateSyncProgressWithServerVersion:serverVersion
                                            clientVersion:clientVersion];
        }];
}


- (void)backgroundApplyChangesetWithServerVersion:(Replication::version_type)serverVersion
                                    clientVersion:(Replication::version_type)clientVersion
                                  originTimestamp:(uint_fast64_t)originTimestamp
                                  originFileIdent:(uint_fast64_t)originFileIdent
                                             data:(NSData *)data {
    using ulonglong = unsigned long long;
    const char *data2 = static_cast<const char *>(data.bytes);
    size_t size = data.length;
    BinaryData changeset(data2, size);
    HistoryEntry::version_type newVersion;
    try {
        Transformer &transformer = *_backgroundTransformer;
        HistoryEntry::version_type lastIntegratedLocalVersion = clientVersion;
        BinaryData remoteChangeset = changeset;
        std::ostream *applyLog = 0;
        newVersion =
            transformer.integrate_remote_changeset(*_backgroundSharedGroup, originTimestamp,
                                                   originFileIdent, lastIntegratedLocalVersion,
                                                   serverVersion, remoteChangeset, applyLog); // Throws
    }
    catch (BadInitialSchemaCreation& e) {
        NSString *message = [NSString stringWithFormat:@"Unresolvable conflict between initial "
                                      "schema-creating changesets: %s", e.what()];
        @throw [NSException exceptionWithName:@"RLMException" reason:message userInfo:nil];
    }
    catch (TransformError& e) {
        NSString *message = [NSString stringWithFormat:@"Bad changeset received: %s", e.what()];
        @throw [NSException exceptionWithName:@"RLMException" reason:message userInfo:nil];
    }

    [[[RLMRealm realmWithPath:_clientPath] notifier] notifyOtherRealms];

    if (s_syncLogEverything) {
        NSLog(@"RealmSync: Connection[%lu]: Session[%@]: Server changeset (%llu -> %llu) "
              "integrated, producing client version %llu", _connection.ident, _sessionIdent,
              ulonglong(serverVersion-1), ulonglong(serverVersion), ulonglong(newVersion));
    }
}


- (void)updateSyncProgressWithServerVersion:(Replication::version_type)serverVersion
                              clientVersion:(Replication::version_type)clientVersion {
    _history->set_sync_progress(serverVersion, clientVersion);
}


- (void)dealloc {
    NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
    __weak RLMServerConnection *weakConnection = _connection;
    NSNumber *sessionIdent = _sessionIdent;
    [mainQueue addOperationWithBlock:^{
            [weakConnection sendUnbindMessageWithSessionIdent:sessionIdent];
        }];
}

@end

static NSString *s_defaultRealmPath = nil;
static NSString * const c_defaultRealmFileName = @"default.realm";

@implementation RLMRealm {
    // Used for read-write realms
    NSHashTable *_notificationHandlers;

    std::unique_ptr<ClientHistory> _history;
    std::unique_ptr<SharedGroup> _sharedGroup;

    // Used for read-only realms
    std::unique_ptr<Group> _readGroup;

    // Used for both
    Group *_group;
    BOOL _readOnly;
    BOOL _inMemory;

    NSURL *_serverBaseURL;
    RLMSyncSession *_syncSession;
}

+ (BOOL)isCoreDebug {
    return realm::Version::has_feature(realm::feature_Debug);
}

+ (void)initialize {
    static bool initialized;
    if (initialized) {
        return;
    }
    initialized = true;

    RLMCheckForUpdates();
    RLMInstallUncaughtExceptionHandler();
    RLMSendAnalytics();
}

- (instancetype)initWithPath:(NSString *)path key:(NSData *)key readOnly:(BOOL)readonly inMemory:(BOOL)inMemory dynamic:(BOOL)dynamic error:(NSError **)outError serverBaseURL:(NSURL *)serverBaseURL {
    self = [super init];
    if (self) {
        _path = path;
        _threadID = pthread_mach_thread_np(pthread_self());
        _notificationHandlers = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
        _readOnly = readonly;
        _inMemory = inMemory;
        _dynamic = dynamic;
        _autorefresh = YES;
        _serverBaseURL = serverBaseURL;

        NSError *error = nil;
        try {
            // NOTE: we do these checks here as is this is the first time encryption keys are used
            key = validatedKey(key);

            if (readonly) {
                _readGroup = make_unique<Group>(path.UTF8String, static_cast<const char *>(key.bytes));
                _group = _readGroup.get();
            }
            else {
                // FIXME: The SharedGroup constructor, when called below, will
                // throw a C++ exception if server_synchronization_mode is
                // inconsistent with the accessed Realm file. This exception
                // probably has to be transmuted to an NSError.
                bool server_synchronization_mode = bool(serverBaseURL);
                if (server_synchronization_mode) {
                    _history = realm::make_client_sync_history(path.UTF8String,
                                                               static_cast<const char *>(key.bytes)); // Throws
                }
                else {
                    _history = realm::make_client_history(path.UTF8String,
                                                          static_cast<const char *>(key.bytes)); // Throws
                }
                SharedGroup::DurabilityLevel durability = inMemory ? SharedGroup::durability_MemOnly :
                                                                     SharedGroup::durability_Full;
                _sharedGroup = make_unique<SharedGroup>(*_history, durability,
                                                        static_cast<const char *>(key.bytes));
            }
        }
        catch (File::PermissionDenied const& ex) {
            NSString *mode = readonly ? @"read" : @"read-write";
            NSString *additionalMessage = [NSString stringWithFormat:@"Unable to open a realm at path '%@'. Please use a path where your app has %@ permissions.", path, mode];
            NSString *newMessage = [NSString stringWithFormat:@"%s\n%@", ex.what(), additionalMessage];
            error = RLMMakeError(RLMErrorFilePermissionDenied,
                                     File::PermissionDenied(newMessage.UTF8String, _path.UTF8String));
        }
        catch (File::Exists const& ex) {
            error = RLMMakeError(RLMErrorFileExists, ex);
        }
        catch (File::AccessError const& ex) {
            error = RLMMakeError(RLMErrorFileAccessError, ex);
        }
        catch (IncompatibleLockFile const&) {
            NSString *err = @"Realm file is currently open in another process "
                             "which cannot share access with this process. All "
                             "processes sharing a single file must be the same "
                             "architecture. For sharing files between the Realm "
                             "Browser and an iOS simulator, this means that you "
                             "must use a 64-bit simulator.";
            error = [NSError errorWithDomain:RLMErrorDomain
                                        code:RLMErrorIncompatibleLockFile
                                    userInfo:@{NSLocalizedDescriptionKey: err,
                                               @"Error Code": @(RLMErrorIncompatibleLockFile)}];
        }
        catch (exception const& ex) {
            error = RLMMakeError(RLMErrorFail, ex);
        }

        if (error) {
            RLMSetErrorOrThrow(error, outError);
            return nil;
        }

    }
    return self;
}

- (realm::Group *)getOrCreateGroup {
    if (!_group) {
        _group = &const_cast<Group&>(_sharedGroup->begin_read());
    }
    return _group;
}

+ (NSString *)defaultRealmPath
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!s_defaultRealmPath) {
            s_defaultRealmPath = [RLMRealm writeablePathForFile:c_defaultRealmFileName];
        }
    });
    return s_defaultRealmPath;
}

+ (void)setDefaultRealmPath:(NSString *)defaultRealmPath {
    s_defaultRealmPath = defaultRealmPath;
}

+ (NSString *)writeableTemporaryPathForFile:(NSString *)fileName
{
    return [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
}

+ (NSString *)writeablePathForFile:(NSString *)fileName
{
#if TARGET_OS_IPHONE
    // On iOS the Documents directory isn't user-visible, so put files there
    NSString *path = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
#else
    // On OS X it is, so put files in Application Support. If we aren't running
    // in a sandbox, put it in a subdirectory based on the bundle identifier
    // to avoid accidentally sharing files between applications
    NSString *path = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0];
    if (![[NSProcessInfo processInfo] environment][@"APP_SANDBOX_CONTAINER_ID"]) {
        NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
        if ([identifier length] == 0) {
            identifier = [[[NSBundle mainBundle] executablePath] lastPathComponent];
        }
        path = [path stringByAppendingPathComponent:identifier];

        // create directory
        [[NSFileManager defaultManager] createDirectoryAtPath:path
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
#endif
    return [path stringByAppendingPathComponent:fileName];
}

+ (instancetype)defaultRealm
{
    return [RLMRealm realmWithPath:[RLMRealm defaultRealmPath] readOnly:NO error:nil];
}

+ (instancetype)realmWithPath:(NSString *)path
{
    return [self realmWithPath:path readOnly:NO error:nil];
}

+ (instancetype)realmWithPath:(NSString *)path
                     readOnly:(BOOL)readonly
                        error:(NSError **)outError
{
    return [self realmWithPath:path key:nil readOnly:readonly inMemory:NO dynamic:NO schema:nil error:outError];
}

+ (instancetype)inMemoryRealmWithIdentifier:(NSString *)identifier {
    return [self realmWithPath:[RLMRealm writeableTemporaryPathForFile:identifier] key:nil
                      readOnly:NO inMemory:YES dynamic:NO schema:nil error:nil];
}

+ (instancetype)realmWithPath:(NSString *)path
                encryptionKey:(NSData *)key
                     readOnly:(BOOL)readonly
                        error:(NSError **)error
{
    if (!key) {
        @throw RLMException(@"Encryption key must not be nil");
    }

    return [self realmWithPath:path key:key readOnly:readonly inMemory:NO dynamic:NO schema:nil error:error];
}

// ARC tries to eliminate calls to autorelease when the value is then immediately
// returned, but this results in significantly different semantics between debug
// and release builds for RLMRealm, so force it to always autorelease.
static id RLMAutorelease(id value) {
    // +1 __bridge_retained, -1 CFAutorelease
    return value ? (__bridge id)CFAutorelease((__bridge_retained CFTypeRef)value) : nil;
}

+ (instancetype)realmWithPath:(NSString *)path
                          key:(NSData *)key
                     readOnly:(BOOL)readonly
                     inMemory:(BOOL)inMemory
                      dynamic:(BOOL)dynamic
                       schema:(RLMSchema *)customSchema
                        error:(NSError **)outError
{
    if (!path || path.length == 0) {
        @throw RLMException(@"Path is not valid", @{@"path":(path ?: @"nil")});
    }

    if (![NSRunLoop currentRunLoop]) {
        @throw RLMException([NSString stringWithFormat:@"%@ \
                                               can only be called from a thread with a runloop.",
                             NSStringFromSelector(_cmd)]);
    }

    if (customSchema && !dynamic) {
        @throw RLMException(@"Custom schema only supported when using dynamic Realms");
    }

    // try to reuse existing realm first
    RLMRealm *realm = RLMGetThreadLocalCachedRealmForPath(path);
    if (realm) {
        if (realm->_readOnly != readonly) {
            @throw RLMException(@"Realm at path already opened with different read permissions", @{@"path":realm.path});
        }
        if (realm->_inMemory != inMemory) {
            @throw RLMException(@"Realm at path already opened with different inMemory settings", @{@"path":realm.path});
        }
        if (realm->_dynamic != dynamic) {
            @throw RLMException(@"Realm at path already opened with different dynamic settings", @{@"path":realm.path});
        }
        return RLMAutorelease(realm);
    }

    key = key ?: keyForPath(path);

    NSURL *serverBaseURL;
    @synchronized (s_serverBaseURLS) {
        serverBaseURL = s_serverBaseURLS[path];
    }

    realm = [[RLMRealm alloc] initWithPath:path key:key readOnly:readonly inMemory:inMemory dynamic:dynamic error:outError serverBaseURL:serverBaseURL];
    if (outError && *outError) {
        return nil;
    }

    // we need to protect the realm cache and accessors cache
    static id initLock = [NSObject new];
    @synchronized(initLock) {
        // create tables, set schema, and create accessors when needed
        if (readonly || (dynamic && !customSchema)) {
            // for readonly realms and dynamic realms without a custom schema just set the schema
            if (realm::ObjectStore::get_schema_version(realm.group) == realm::ObjectStore::NotVersioned) {
                RLMSetErrorOrThrow([NSError errorWithDomain:RLMErrorDomain code:RLMErrorFail userInfo:@{NSLocalizedDescriptionKey:@"Cannot open an uninitialized realm in read-only mode"}], outError);
                return nil;
            }
            RLMSchema *targetSchema = readonly ? [RLMSchema.sharedSchema copy] : [RLMSchema dynamicSchemaFromRealm:realm];
            RLMRealmSetSchema(realm, targetSchema, true);
            RLMRealmCreateAccessors(realm.schema);
        }
        else {
            // check cache for existing cached realms with the same path
            RLMRealm *existingRealm = RLMGetAnyCachedRealmForPath(path);
            if (existingRealm) {
                // if we have a cached realm on another thread, copy without a transaction
                RLMRealmSetSchema(realm, [existingRealm.schema shallowCopy], false);

                // Ensured by the SharedGroup constructor.
                REALM_ASSERT(bool(existingRealm->_serverBaseURL) == bool(realm->_serverBaseURL));

                if (realm->_serverBaseURL) {
                    if (![realm->_serverBaseURL isEqual:existingRealm->_serverBaseURL]) {
                        @throw [NSException exceptionWithName:@"RLMException"
                                                       reason:@"Server synchronization URL mismatch"
                                                     userInfo:nil];
                    }
                    realm->_syncSession = existingRealm->_syncSession;
                }
            }
            else {
                RLMSyncSession *session = 0;
                // FIXME: A file cannot be reliably identified by its path. A
                // safe approach is to start by opening the file, then get the
                // inode and device numbers from the file descriptor, then use
                // that pair as a key to lookup a preexisting RLMRealm
                // instance. If one is found, the opened file can be closed. If
                // one is not found, a new RLMRealm instance can be created from
                // the handle of the open file. Alternatively, on a system with
                // a proc filesystem, on can use the path to the file descriptor
                // as a basis for constructing the new RLMInstance. Note that
                // the inode number is only guaranteed to stay valid for as long
                // as you hold on the the handle of the open file.
                session = [s_syncSessions objectForKey:realm.path];
                if (!session) {
                    if (serverBaseURL) {
                        NSString *hostKey = serverBaseURL.host;
                        if (serverBaseURL.port) {
                            hostKey = [NSString stringWithFormat:@"%@:%@", serverBaseURL.host, serverBaseURL.port];
                        }
                        RLMServerConnection *conn = [s_serverConnections objectForKey:hostKey];
                        if (!conn) {
                            unsigned long serverConnectionIdent = ++s_lastServerConnectionIdent;
                            conn = [[RLMServerConnection alloc] initWithIdent:serverConnectionIdent
                                                                      address:serverBaseURL.host
                                                                         port:serverBaseURL.port];
                            [s_serverConnections setObject:conn forKey:hostKey];
                        }
                        session = [[RLMSyncSession alloc] initWithConnection:conn
                                                                  serverPath:serverBaseURL.path
                                                                  clientPath:realm.path];
                        [s_syncSessions setObject:session forKey:realm.path];
                        NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
                        __weak RLMSyncSession *weakSession = session;
                        [mainQueue addOperationWithBlock:^{
                                [weakSession mainThreadInit];
                            }];
                    }
                }
                realm->_syncSession = session;

                // if we are the first realm at this path, set/align schema or perform migration if needed
                RLMSchema *targetSchema = customSchema ?: RLMSchema.sharedSchema;
                @try {
                    RLMUpdateRealmToSchemaVersion(realm, schemaVersionForPath(path), [targetSchema copy], [realm migrationBlock:key]);
                }
                @catch (NSException *exception) {
                    RLMSetErrorOrThrow(RLMMakeError(exception), outError);
                    return nil;
                }

                RLMRealmCreateAccessors(realm.schema);
            }

            // initializing the schema started a read transaction, so end it
            [realm invalidate];
        }

        if (!dynamic) {
            RLMCacheRealm(realm);
        }
    }

    if (!readonly) {
        realm.notifier = [[RLMNotifier alloc] initWithRealm:realm error:outError];
        if (!realm.notifier) {
            return nil;
        }
    }

    return RLMAutorelease(realm);
}

- (NSError *(^)())migrationBlock:(NSData *)encryptionKey {
    RLMMigrationBlock userBlock = migrationBlockForPath(_path);
    if (userBlock) {
        return ^{
            NSError *error;
            RLMMigration *migration = [[RLMMigration alloc] initWithRealm:self key:encryptionKey error:&error];
            if (error) {
                return error;
            }

            [migration execute:userBlock];
            return error;
        };
    }
    return nil;
}

+ (void)setEncryptionKey:(NSData *)key forRealmsAtPath:(NSString *)path {
    @synchronized (s_keysPerPath) {
        if (RLMGetAnyCachedRealmForPath(path)) {
            NSData *existingKey = keyForPath(path);
            if (!(existingKey == key || [existingKey isEqual:key])) {
                @throw RLMException(@"Cannot set encryption key for Realms that are already open.");
            }
        }

        setKeyForPath(key, path);
    }
}

+ (void)resetRealmState {
    clearMigrationCache();
    clearKeyCache();
    RLMClearRealmCache();
    s_defaultRealmPath = [RLMRealm writeablePathForFile:c_defaultRealmFileName];
}

static void CheckReadWrite(RLMRealm *realm, NSString *msg=@"Cannot write to a read-only Realm") {
    if (realm->_readOnly) {
        @throw RLMException(msg);
    }
}

- (RLMNotificationToken *)addNotificationBlock:(RLMNotificationBlock)block {
    RLMCheckThread(self);
    CheckReadWrite(self, @"Read-only Realms do not change and do not have change notifications");
    if (!block) {
        @throw RLMException(@"The notification block should not be nil");
    }

    RLMNotificationToken *token = [[RLMNotificationToken alloc] init];
    token.realm = self;
    token.block = block;
    [_notificationHandlers addObject:token];
    return token;
}

- (void)removeNotification:(RLMNotificationToken *)token {
    RLMCheckThread(self);
    if (token) {
        [_notificationHandlers removeObject:token];
        token.realm = nil;
        token.block = nil;
    }
}

- (void)sendNotifications:(NSString *)notification {
    NSAssert(!_readOnly, @"Read-only realms do not have notifications");

    // call this realms notification blocks
    for (RLMNotificationToken *token in [_notificationHandlers allObjects]) {
        if (token.block) {
            token.block(notification, self);
        }
    }
}

- (void)beginWriteTransaction {
    CheckReadWrite(self);
    RLMCheckThread(self);

    if (!self.inWriteTransaction) {
        try {
            // if the upgrade to write will move the transaction forward,
            // announce the change after promoting
            bool announce = _sharedGroup->has_changed();

            // begin the read transaction if needed
            [self getOrCreateGroup];

            LangBindHelper::promote_to_write(*_sharedGroup, *_history);

            // update state and make all objects in this realm writable
            _inWriteTransaction = YES;

            if (announce) {
                [self sendNotifications:RLMRealmDidChangeNotification];
            }
        }
        catch (std::exception& ex) {
            // File access errors are treated as exceptions here since they should not occur after the shared
            // group has already been successfully opened on the file and memory mapped. The shared group constructor handles
            // the excepted error related to file access.
            @throw RLMException(ex);
        }
    } else {
        @throw RLMException(@"The Realm is already in a write transaction");
    }
}

- (void)commitWriteTransaction {
    CheckReadWrite(self);
    RLMCheckThread(self);

    if (self.inWriteTransaction) {
        try {
            LangBindHelper::commit_and_continue_as_read(*_sharedGroup);

            // update state and make all objects in this realm read-only
            _inWriteTransaction = NO;

            // notify other realm instances of changes
            [self.notifier notifyOtherRealms];

            // send local notification
            [self sendNotifications:RLMRealmDidChangeNotification];

            NSOperationQueue *mainQueue = [NSOperationQueue mainQueue];
            __weak RLMSyncSession *weakSession = _syncSession;
            [mainQueue addOperationWithBlock:^{
                [weakSession refreshLatestVersionAvailable];
            }];
        }
        catch (std::exception& ex) {
            @throw RLMException(ex);
        }
    } else {
       @throw RLMException(@"Can't commit a non-existing write transaction");
    }
}

- (void)transactionWithBlock:(void(^)(void))block {
    [self beginWriteTransaction];
    block();
    if (_inWriteTransaction) {
        [self commitWriteTransaction];
    }
}

- (void)cancelWriteTransaction {
    CheckReadWrite(self);
    RLMCheckThread(self);

    if (self.inWriteTransaction) {
        try {
            LangBindHelper::rollback_and_continue_as_read(*_sharedGroup, *_history);
            _inWriteTransaction = NO;
        }
        catch (std::exception& ex) {
            @throw RLMException(ex);
        }
    } else {
        @throw RLMException(@"Can't cancel a non-existing write transaction");
    }
}

- (void)invalidate {
    RLMCheckThread(self);
    CheckReadWrite(self, @"Cannot invalidate a read-only realm");

    if (_inWriteTransaction) {
        NSLog(@"WARNING: An RLMRealm instance was invalidated during a write "
              "transaction and all pending changes have been rolled back.");
        [self cancelWriteTransaction];
    }
    if (!_group) {
        // Nothing to do if the read transaction hasn't been begun
        return;
    }

    _sharedGroup->end_read();
    _group = nullptr;
    for (RLMObjectSchema *objectSchema in _schema.objectSchema) {
        objectSchema.table = nullptr;
    }
}

/**
 Replaces all string columns in this Realm with a string enumeration column and compacts the
 database file.

 Cannot be called from a write transaction.

 Compaction will not occur if other `RLMRealm` instances exist.

 While compaction is in progress, attempts by other threads or processes to open the database will
 wait.

 Be warned that resource requirements for compaction is proportional to the amount of live data in
 the database.

 Compaction works by writing the database contents to a temporary database file and then replacing
 the database with the temporary one. The name of the temporary file is formed by appending
 `.tmp_compaction_space` to the name of the database.

 @return YES if the compaction succeeded.
 */
- (BOOL)compact
{
    RLMCheckThread(self);
    BOOL compactSucceeded = NO;
    if (!_inWriteTransaction) {
        try {
            for (RLMObjectSchema *objectSchema in _schema.objectSchema) {
                objectSchema.table->optimize();
            }
            _sharedGroup->end_read();
            compactSucceeded = _sharedGroup->compact();
            _sharedGroup->begin_read();
        }
        catch (std::exception& ex) {
            @throw RLMException(ex);
        }
    } else {
        @throw RLMException(@"Can't compact a Realm within a write transaction");
    }
    return compactSucceeded;
}

- (void)dealloc {
    if (_inWriteTransaction) {
        [self cancelWriteTransaction];
        NSLog(@"WARNING: An RLMRealm instance was deallocated during a write transaction and all "
              "pending changes have been rolled back. Make sure to retain a reference to the "
              "RLMRealm for the duration of the write transaction.");
    }
    [_notifier stop];
}

- (void)handleExternalCommit {
    RLMCheckThread(self);
    NSAssert(!_readOnly, @"Read-only realms do not have notifications");
    try {
        if (_sharedGroup->has_changed()) { // Throws
            if (_autorefresh) {
                if (_group) {
                    LangBindHelper::advance_read(*_sharedGroup, *_history);
                }
                [self sendNotifications:RLMRealmDidChangeNotification];
            }
            else {
                [self sendNotifications:RLMRealmRefreshRequiredNotification];
            }
        }
    }
    catch (exception &ex) {
        @throw RLMException(ex);
    }
}

- (BOOL)refresh {
    RLMCheckThread(self);
    CheckReadWrite(self, @"Cannot refresh a read-only realm (external modifications to read only realms are not supported)");

    // can't be any new changes if we're in a write transaction
    if (self.inWriteTransaction) {
        return NO;
    }

    try {
        // advance transaction if database has changed
        if (_sharedGroup->has_changed()) { // Throws
            if (_group) {
                LangBindHelper::advance_read(*_sharedGroup, *_history);
            }
            else {
                // Create the read transaction
                [self getOrCreateGroup];
            }
            [self sendNotifications:RLMRealmDidChangeNotification];
            return YES;
        }
        return NO;
    }
    catch (exception &ex) {
        @throw RLMException(ex);
    }
}

- (void)addObject:(__unsafe_unretained RLMObject *const)object {
    RLMAddObjectToRealm(object, self, false);
}

- (void)addObjects:(id<NSFastEnumeration>)array {
    for (RLMObject *obj in array) {
        if (![obj isKindOfClass:[RLMObject class]]) {
            NSString *msg = [NSString stringWithFormat:@"Cannot insert objects of type %@ with addObjects:. Only RLMObjects are supported.", NSStringFromClass(obj.class)];
            @throw RLMException(msg);
        }
        [self addObject:obj];
    }
}

- (void)addOrUpdateObject:(RLMObject *)object {
    // verify primary key
    if (!object.objectSchema.primaryKeyProperty) {
        NSString *reason = [NSString stringWithFormat:@"'%@' does not have a primary key and can not be updated", object.objectSchema.className];
        @throw RLMException(reason);
    }

    RLMAddObjectToRealm(object, self, true);
}

- (void)addOrUpdateObjectsFromArray:(id)array {
    for (RLMObject *obj in array) {
        [self addOrUpdateObject:obj];
    }
}

- (void)deleteObject:(RLMObject *)object {
    RLMDeleteObjectFromRealm(object, self);
}

- (void)deleteObjects:(id)array {
    if ([array respondsToSelector:@selector(realm)] && [array respondsToSelector:@selector(deleteObjectsFromRealm)]) {
        if (self != (RLMRealm *)[array realm]) {
            @throw RLMException(@"Can only delete objects from the Realm they belong to.");
        }
        [array deleteObjectsFromRealm];
    }
    else if ([array conformsToProtocol:@protocol(NSFastEnumeration)]) {
        for (id obj in array) {
            if ([obj isKindOfClass:RLMObjectBase.class]) {
                RLMDeleteObjectFromRealm(obj, self);
            }
        }
    }
    else {
        @throw RLMException(@"Invalid array type - container must be an RLMArray, RLMArray, or NSArray of RLMObjects");
    }
}

- (void)deleteAllObjects {
    RLMDeleteAllObjectsFromRealm(self);
}

- (RLMResults *)allObjects:(NSString *)objectClassName {
    return RLMGetObjects(self, objectClassName, nil);
}

- (RLMResults *)objects:(NSString *)objectClassName where:(NSString *)predicateFormat, ... {
    va_list args;
    RLM_VARARG(predicateFormat, args);
    return [self objects:objectClassName where:predicateFormat args:args];
}

- (RLMResults *)objects:(NSString *)objectClassName where:(NSString *)predicateFormat args:(va_list)args {
    return [self objects:objectClassName withPredicate:[NSPredicate predicateWithFormat:predicateFormat arguments:args]];
}

- (RLMResults *)objects:(NSString *)objectClassName withPredicate:(NSPredicate *)predicate {
    return RLMGetObjects(self, objectClassName, predicate);
}

+ (void)setDefaultRealmSchemaVersion:(uint64_t)version withMigrationBlock:(RLMMigrationBlock)block {
    [RLMRealm setSchemaVersion:version forRealmAtPath:[RLMRealm defaultRealmPath] withMigrationBlock:block];
}

+ (void)setSchemaVersion:(uint64_t)version forRealmAtPath:(NSString *)realmPath withMigrationBlock:(RLMMigrationBlock)block {
    @synchronized(s_migrationBlocks) {
        if (RLMGetAnyCachedRealmForPath(realmPath) && schemaVersionForPath(realmPath) != version) {
            @throw RLMException(@"Cannot set schema version for Realms that are already open.");
        }

        if (version == realm::ObjectStore::NotVersioned) {
            @throw RLMException(@"Cannot set schema version to RLMNotVersioned.");
        }

        if (block) {
            s_migrationBlocks[realmPath] = block;
        }
        else {
            [s_migrationBlocks removeObjectForKey:realmPath];
        }
        s_schemaVersions[realmPath] = @(version);
    }
}

+ (uint64_t)schemaVersionAtPath:(NSString *)realmPath error:(NSError **)error {
    return [RLMRealm schemaVersionAtPath:realmPath encryptionKey:nil error:error];
}

+ (uint64_t)schemaVersionAtPath:(NSString *)realmPath encryptionKey:(NSData *)key error:(NSError **)outError {
    key = validatedKey(key) ?: keyForPath(realmPath);
    RLMRealm *realm = RLMGetThreadLocalCachedRealmForPath(realmPath);
    if (!realm) {
        NSError *error;
        realm = [[RLMRealm alloc] initWithPath:realmPath key:key readOnly:YES inMemory:NO dynamic:YES error:&error serverBaseURL:nil];
        if (error) {
            RLMSetErrorOrThrow(error, outError);
            return RLMNotVersioned;
        }
    }

    return realm::ObjectStore::get_schema_version(realm.group);
}

+ (NSError *)migrateRealmAtPath:(NSString *)realmPath {
    return [self migrateRealmAtPath:realmPath key:keyForPath(realmPath)];
}

+ (NSError *)migrateRealmAtPath:(NSString *)realmPath encryptionKey:(NSData *)key {
    if (!key) {
        @throw RLMException(@"Encryption key must not be nil");
    }

    return [self migrateRealmAtPath:realmPath key:validatedKey(key)];
}

+ (NSError *)migrateRealmAtPath:(NSString *)realmPath key:(NSData *)key {
    if (RLMGetAnyCachedRealmForPath(realmPath)) {
        @throw RLMException(@"Cannot migrate Realms that are already open.");
    }

    key = validatedKey(key) ?: keyForPath(realmPath);

    NSError *error;
    RLMRealm *realm = [[RLMRealm alloc] initWithPath:realmPath key:key readOnly:NO inMemory:NO dynamic:YES error:&error serverBaseURL:nil];
    if (error)
        return error;

    @try {
        RLMUpdateRealmToSchemaVersion(realm, schemaVersionForPath(realmPath), [RLMSchema.sharedSchema copy], [realm migrationBlock:key]);
    } @catch (NSException *ex) {
        return RLMMakeError(ex);
    }
    return nil;
}

- (RLMObject *)createObject:(NSString *)className withValue:(id)value {
    return (RLMObject *)RLMCreateObjectInRealmWithValue(self, className, value, false);
}

+ (void)enableServerSyncOnPath:(NSString *)path serverBaseURL:(NSString *)serverBaseURL {
    NSURL *url = [NSURL URLWithString:serverBaseURL];
    // The URL must specify a scheme, a host, and a path, and the
    // scheme must be 'realm'.
    bool good = url && url.scheme && url.host && url.path &&
        !url.user && !url.query && !url.fragment &&
        [url.scheme.lowercaseString isEqualToString:@"realm"];
    if (!good)
        @throw [NSException exceptionWithName:@"RLMException" reason:@"Bad URL" userInfo:nil];
    @synchronized (s_serverBaseURLS) {
        s_serverBaseURLS[path] = url;
    }
}

+ (void)setServerSyncLogLevel:(int)level {
    s_syncLogEverything = (level >= 2);
}

- (BOOL)writeCopyToPath:(NSString *)path key:(NSData *)key error:(NSError **)error {
    key = validatedKey(key) ?: keyForPath(path);

    try {
        self.group->write(path.UTF8String, static_cast<const char *>(key.bytes));
        return YES;
    }
    catch (File::PermissionDenied &ex) {
        if (error) {
            *error = RLMMakeError(RLMErrorFilePermissionDenied, ex);
        }
    }
    catch (File::Exists &ex) {
        if (error) {
            *error = RLMMakeError(RLMErrorFileExists, ex);
        }
    }
    catch (File::AccessError &ex) {
        if (error) {
            *error = RLMMakeError(RLMErrorFileAccessError, ex);
        }
    }
    catch (exception &ex) {
        if (error) {
            *error = RLMMakeError(RLMErrorFail, ex);
        }
    }

    return NO;
}

- (BOOL)writeCopyToPath:(NSString *)path error:(NSError **)error {
    return [self writeCopyToPath:path key:nil error:error];
}

- (BOOL)writeCopyToPath:(NSString *)path encryptionKey:(NSData *)key error:(NSError **)error {
    if (!key) {
        @throw RLMException(@"Encryption key must not be nil");
    }

    return [self writeCopyToPath:path key:key error:error];
}

- (realm::SharedGroup *)sharedGroup {
    return _sharedGroup.get();
}

@end
