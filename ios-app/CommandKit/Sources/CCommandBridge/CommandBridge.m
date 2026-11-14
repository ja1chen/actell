#import "CommandBridge.h"
#import <ios_system/ios_system.h>
#import <unistd.h>
#import <pthread.h>
#import <time.h>
#import <errno.h>
#import <dispatch/dispatch.h>

static const NSUInteger outputLimit = 65536;
static const char sessionKey[] = "actell-command-tools";
// The upstream runtime has process-global session state: serialize every caller,
// including callers that do not use the Swift actor.
static pthread_mutex_t runtimeLock = PTHREAD_MUTEX_INITIALIZER;

@implementation CommandExecution {
    NSLock *_stateLock;
    BOOL _cancelled;
    BOOL _active;
}
+ (NSArray<NSString *> *)availableCommands {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"commandDictionary" ofType:@"plist"];
    NSDictionary *commands = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    return commands ? [commands.allKeys sortedArrayUsingSelector:@selector(compare:)] : @[];
}
- (instancetype)init {
    if ((self = [super init])) _stateLock = [NSLock new];
    return self;
}
- (void)cancel {
    [_stateLock lock]; _cancelled = YES; [_stateLock unlock];
}
- (NSDictionary<NSString *, id> *)run:(NSString *)command directory:(NSURL *)directory root:(NSURL *)root timeout:(double)timeout {
    pthread_mutex_lock(&runtimeLock);
    [_stateLock lock];
    if (_cancelled) {
        [_stateLock unlock]; pthread_mutex_unlock(&runtimeLock);
        return @{ @"stdout": @"", @"stderr": @"", @"exitCode": @130, @"truncated": @NO, @"timedOut": @NO };
    }
    [_stateLock unlock];
    if (![[NSBundle mainBundle] pathForResource:@"commandDictionary" ofType:@"plist"]) {
        pthread_mutex_unlock(&runtimeLock);
        return @{ @"stdout": @"", @"stderr": @"Missing commandDictionary.plist in app resources", @"exitCode": @127, @"truncated": @NO, @"timedOut": @NO };
    }
    int outPipe[2] = {-1, -1}, errPipe[2] = {-1, -1};
    FILE *input = fopen("/dev/null", "r");
    if (!input || pipe(outPipe) != 0 || pipe(errPipe) != 0) {
        if (input) fclose(input);
        for (int i = 0; i < 2; i++) { if (outPipe[i] >= 0) close(outPipe[i]); if (errPipe[i] >= 0) close(errPipe[i]); }
        pthread_mutex_unlock(&runtimeLock);
        return @{ @"stdout": @"", @"stderr": @"Cannot create command streams", @"exitCode": @127, @"truncated": @NO, @"timedOut": @NO };
    }
    FILE *output = fdopen(outPipe[1], "w"), *error = fdopen(errPipe[1], "w");
    if (!output || !error) {
        fclose(input);
        if (output) fclose(output); else close(outPipe[1]);
        if (error) fclose(error); else close(errPipe[1]);
        close(outPipe[0]); close(errPipe[0]); pthread_mutex_unlock(&runtimeLock);
        return @{ @"stdout": @"", @"stderr": @"Cannot open command streams", @"exitCode": @127, @"truncated": @NO, @"timedOut": @NO };
    }
    NSMutableData *outData = [NSMutableData data], *errData = [NSMutableData data];
    __block BOOL outTruncated = NO, errTruncated = NO;
    dispatch_group_t readers = dispatch_group_create();
    void (^drain)(int, NSMutableData *, BOOL *) = ^(int fd, NSMutableData *data, BOOL *truncated) {
        char bytes[4096]; ssize_t count;
        while (YES) {
            count = read(fd, bytes, sizeof(bytes));
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            NSUInteger available = outputLimit - data.length;
            NSUInteger keep = MIN((NSUInteger)count, available);
            if (keep) [data appendBytes:bytes length:keep];
            if (keep < (NSUInteger)count) *truncated = YES;
        }
        close(fd);
    };
    int outRead = outPipe[0], errRead = errPipe[0];
    dispatch_group_async(readers, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ drain(outRead, outData, &outTruncated); });
    dispatch_group_async(readers, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ drain(errRead, errData, &errTruncated); });
    NSString *previousDirectory = [NSFileManager.defaultManager currentDirectoryPath];
    [_stateLock lock];
    ios_switchSession(sessionKey);
    ios_setContext(sessionKey); // Reusing this session then avoids upstream cwd switching.
    FILE *previousInput = thread_stdin, *previousOutput = thread_stdout, *previousError = thread_stderr;
    bool previousSideLoading = sideLoading, previousJoin = joinMainThread;
    void *previousContext = thread_context;
    thread_context = (void *)sessionKey;
    // Initialize only the generated registry; no optional module dictionaries are needed.
    sideLoading = false;
    (void)commandsAsArray();
    sideLoading = true; joinMainThread = true;
    // Mini-root constrains cd/tilde expansion, not absolute file access.
    BOOL directoryReady = ios_setMiniRoot(root.path) != 0;
    if (directoryReady) ios_setDirectoryURL(directory);
    directoryReady = directoryReady && [[NSFileManager.defaultManager currentDirectoryPath]
        isEqualToString:directory.path.stringByResolvingSymlinksInPath];
    ios_setStreams(input, output, error);
    thread_stdin = input; thread_stdout = output; thread_stderr = error;
    _active = YES;
    [_stateLock unlock];
    __block BOOL timedOut = NO;
    uint64_t started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    dispatch_queue_t watchdogQueue = dispatch_queue_create("actell.command.watchdog", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, watchdogQueue);
    dispatch_source_set_timer(watchdog, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), 100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(watchdog, ^{
        [self->_stateLock lock];
        if (self->_active) {
            double elapsed = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started) / 1e9;
            if (elapsed >= timeout) timedOut = YES;
            if (self->_cancelled || timedOut) {
                // ios_system's currentSession is thread-local, including on the watchdog queue.
                ios_switchSession(sessionKey);
                ios_kill();
            }
        }
        [self->_stateLock unlock];
    });
    dispatch_resume(watchdog);
    // A fresh library-local environment and aliases prevent cross-invocation leakage.
    extern char **environ;
    storeEnvironment(environ);
    int status;
    if (directoryReady) {
        ios_system("unalias -a");
        status = ios_system(command.UTF8String);
    } else {
        fprintf(error, "Cannot enter command working directory\n");
        status = 1;
    }
    [_stateLock lock]; _active = NO; [_stateLock unlock];
    dispatch_source_cancel(watchdog);
    dispatch_sync(watchdogQueue, ^{});
    storeEnvironment(environ);
    if (previousDirectory) [NSFileManager.defaultManager changeCurrentDirectoryPath:previousDirectory];
    fflush(output); fflush(error);
    ios_setStreams(NULL, NULL, NULL);
    thread_stdin = previousInput; thread_stdout = previousOutput; thread_stderr = previousError;
    thread_context = previousContext;
    sideLoading = previousSideLoading; joinMainThread = previousJoin;
    fclose(input); fclose(output); fclose(error);
    dispatch_group_wait(readers, DISPATCH_TIME_FOREVER);
    // Keep the one runtime session for reuse; upstream closeSession does not free its allocation.
    pthread_mutex_unlock(&runtimeLock);
    // Preserve bytes for Swift's lossy UTF-8 decoder. The capture limit can
    // split a multibyte scalar; never reinterpret the whole stream as Latin-1.
    return @{ @"stdout": outData, @"stderr": errData, @"exitCode": @(timedOut ? 124 : status),
              @"truncated": @(outTruncated || errTruncated), @"timedOut": @(timedOut) };
}
@end
