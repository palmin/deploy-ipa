// linked into every target of a deploy-ipa console build: uploads stdout, stderr and the
// process's own os_log lines to S3 every two seconds, with an upload policy compiled in
#import <Foundation/Foundation.h>
#import <OSLog/OSLog.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef REMOTE_CONSOLE_CONFIG
#error define REMOTE_CONSOLE_CONFIG as the base64 encoded upload config
#endif

static dispatch_queue_t queue, logStoreQueue;
static dispatch_source_t timer, logStoreTimer;
static NSURLSession *session;
static NSDictionary *config;
static NSString *keyPrefix;
static NSString *processName;
static NSDateFormatter *timeFormatter;
static NSRegularExpression *nslogPrefix;
static NSDate *launchDate;
static NSMutableArray<NSArray *> *pending; // [date, line] pairs
static NSUInteger pendingLength;
static NSUInteger sequence;
static BOOL uploading, disabled;

static void enqueue(NSDate *date, NSString *line) {
    dispatch_async(queue, ^{
        // a stalled upload must not grow without bound
        if (pendingLength > (4 << 20)) {
            NSRange oldest = NSMakeRange(0, pending.count / 2);
            for (NSArray *item in [pending subarrayWithRange:oldest]) pendingLength -= [item[1] length];
            [pending removeObjectsInRange:oldest];
            [pending insertObject:@[date, @"RemoteConsole: dropped older lines"] atIndex:0];
        }
        [pending addObject:@[date, line]];
        pendingLength += line.length;
    });
}

// read what the process writes to fd, still passing it on to where fd pointed before
static void capture(int fd) {
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return;
    int original = dup(fd);
    dup2(fds[1], fd);
    close(fds[1]);
    int input = fds[0];

    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        NSMutableData *partial = [NSMutableData data];
        char buffer[16384];
        ssize_t count;
        while ((count = read(input, buffer, sizeof buffer)) > 0) {
            @autoreleasepool {
                if (original >= 0) write(original, buffer, count);
                [partial appendBytes:buffer length:count];
                const char *bytes = partial.bytes;
                NSUInteger start = 0;
                for (NSUInteger i = 0; i < partial.length; i++) {
                    if (bytes[i] != '\n') continue;
                    NSString *line = [[NSString alloc] initWithBytes:bytes + start length:i - start
                                                            encoding:NSUTF8StringEncoding] ?: @"(line not UTF-8)";
                    // NSLog adds its own date and process, which every line already gets
                    line = [nslogPrefix stringByReplacingMatchesInString:line options:0
                                                                   range:NSMakeRange(0, line.length) withTemplate:@""];
                    enqueue([NSDate date], line);
                    start = i + 1;
                }
                [partial replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            }
        }
    }];
    thread.name = fd == STDOUT_FILENO ? @"RemoteConsole stdout" : @"RemoteConsole stderr";
    [thread start];
}

// Logger and os_log lines from the process's own code or its own subsystems
static void pollLogStore(void) API_AVAILABLE(ios(15.0), macos(12.0)) {
    static OSLogStore *store;
    static NSDate *after;
    static NSSet<NSString *> *senders;
    static NSString *subsystemPrefix;
    static NSUInteger reads;
    if (reads == NSNotFound) return;
    if (store == nil) {
        store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:nil];
        if (store == nil) return;
        after = launchDate;
        NSString *executable = NSBundle.mainBundle.executablePath.lastPathComponent ?: processName;
        senders = [NSSet setWithObjects:executable, [executable stringByAppendingString:@".debug.dylib"], nil];
        NSArray *parts = [NSBundle.mainBundle.bundleIdentifier componentsSeparatedByString:@"."];
        subsystemPrefix = parts.count >= 2 ? [NSString stringWithFormat:@"%@.%@.", parts[0], parts[1]] : @"\n";
    }

    NSDate *started = [NSDate date];
    OSLogPosition *position = [store positionWithDate:after];
    for (OSLogEntry *entry in [store entriesEnumeratorWithOptions:0 position:position predicate:nil error:nil]) {
        if (![entry isKindOfClass:OSLogEntryLog.class] || [entry.date compare:after] != NSOrderedDescending) continue;
        after = entry.date;
        OSLogEntryLog *log = (OSLogEntryLog *)entry;
        BOOL own = log.subsystem.length == 0 ? [senders containsObject:log.sender] : [log.subsystem hasPrefix:subsystemPrefix];
        if (!own) continue;
        NSString *category = log.category.length > 0 ? [NSString stringWithFormat:@"[%@] ", log.category] : @"";
        enqueue(entry.date, [category stringByAppendingString:entry.composedMessage]);
    }

    // reading can be slow on a device; print and NSLog do not depend on it
    NSTimeInterval took = -started.timeIntervalSinceNow;
    reads += 1;
    if (took > 5) {
        reads = NSNotFound;
        enqueue([NSDate date], [NSString stringWithFormat:@"RemoteConsole: stopped reading Logger lines, one read took %.1fs", took]);
    } else if (reads == 1) {
        enqueue([NSDate date], [NSString stringWithFormat:@"RemoteConsole: first read of Logger lines took %.2fs", took]);
    }
}

static NSURLRequest *uploadRequest(NSString *key, NSData *body) {
    NSString *boundary = NSUUID.UUID.UUIDString;
    NSMutableData *data = [NSMutableData data];
    void (^field)(NSString *, NSString *) = ^(NSString *name, NSString *value) {
        NSString *part = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n",
                          boundary, name, value];
        [data appendData:[part dataUsingEncoding:NSUTF8StringEncoding]];
    };
    field(@"key", key);
    [config[@"fields"] enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        field(name, value);
    }];
    NSString *file = [NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"console.log\"\r\n"
                      @"Content-Type: text/plain\r\n\r\n", boundary];
    [data appendData:[file dataUsingEncoding:NSUTF8StringEncoding]];
    [data appendData:body];
    [data appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:config[@"url"]]];
    request.HTTPMethod = @"POST";
    [request setValue:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = data;
    return request;
}

static void requeue(NSArray<NSArray *> *batch) {
    [pending insertObjects:batch atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, batch.count)]];
    for (NSArray *item in batch) pendingLength += [item[1] length];
}

static void upload(NSURLRequest *request, NSArray<NSArray *> *batch, dispatch_block_t finished) {
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_async(queue, ^{
            uploading = NO;
            if (status >= 200 && status < 300) {
                sequence += 1;
            } else if (status == 403) {
                // the upload policy expired with the install link
                disabled = YES;
            } else {
                requeue(batch);
            }
        });
        finished();
    }] resume];
}

static void flush(void) {
    if (uploading || disabled || pending.count == 0) return;
    NSArray<NSArray *> *batch = [pending sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [a[0] compare:b[0]];
    }];
    [pending removeAllObjects];
    pendingLength = 0;

    NSMutableString *text = [NSMutableString string];
    for (NSArray *item in batch) {
        [text appendFormat:@"%@ %@ %@\n", [timeFormatter stringFromDate:item[0]], processName, item[1]];
    }
    NSString *key = [NSString stringWithFormat:@"%@%06lu.log", keyPrefix, (unsigned long)sequence];
    NSURLRequest *request = uploadRequest(key, [text dataUsingEncoding:NSUTF8StringEncoding]);
    uploading = YES;

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    upload(request, batch, ^{ dispatch_semaphore_signal(done); });
#if !TARGET_OS_OSX
    // keep running until the upload finishes, should the app go to the background meanwhile
    [NSProcessInfo.processInfo performExpiringActivityWithReason:@"RemoteConsole upload" usingBlock:^(BOOL expired) {
        if (!expired) dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    }];
#endif
}

__attribute__((constructor)) static void RemoteConsoleStart(void) {
    // a framework linking this file too must not start a second copy in this process
    if (getenv("REMOTE_CONSOLE_STARTED") != NULL) return;
    setenv("REMOTE_CONSOLE_STARTED", "1", 1);

    @autoreleasepool {
        launchDate = [NSDate date];
        NSData *json = [[NSData alloc] initWithBase64EncodedString:@(REMOTE_CONSOLE_CONFIG) options:0];
        config = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
        if (![config isKindOfClass:NSDictionary.class]) return;

        NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@" /\\:"];
        processName = [[NSProcessInfo.processInfo.processName componentsSeparatedByCharactersInSet:unsafe]
                       componentsJoinedByString:@"-"];
        NSDateFormatter *launch = [NSDateFormatter new];
        launch.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        launch.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        launch.dateFormat = @"yyyyMMdd-HHmmss";
        keyPrefix = [NSString stringWithFormat:@"%@%@-%@-%d/", config[@"prefix"], [launch stringFromDate:[NSDate date]],
                     processName, NSProcessInfo.processInfo.processIdentifier];

        timeFormatter = [NSDateFormatter new];
        timeFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        timeFormatter.dateFormat = @"HH:mm:ss.SSS";
        nslogPrefix = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d\\d-\\d\\d \\d\\d:\\d\\d:\\d\\d\\.\\d+ [^\\[]*\\[\\d+:[0-9a-fx]+\\] "
                                                                options:0 error:nil];
        pending = [NSMutableArray array];
        queue = dispatch_queue_create("RemoteConsole", DISPATCH_QUEUE_SERIAL);
        session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];

        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        enqueue([NSDate date], [NSString stringWithFormat:@"RemoteConsole: %@ %@ (%@) on %@",
                                NSBundle.mainBundle.bundleIdentifier, info[@"CFBundleShortVersionString"],
                                info[@"CFBundleVersion"], NSProcessInfo.processInfo.operatingSystemVersionString]);

        // NSLog copies itself to stderr outside of Xcode only when told to
        setenv("CFLOG_FORCE_STDERR", "1", 1);
        setvbuf(stdout, NULL, _IOLBF, 0);
        capture(STDOUT_FILENO);
        capture(STDERR_FILENO);

        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(timer, ^{ flush(); });
        dispatch_resume(timer);

        // on its own queue, so a slow read never holds back uploads
        logStoreQueue = dispatch_queue_create("RemoteConsole log store", DISPATCH_QUEUE_SERIAL);
        logStoreTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, logStoreQueue);
        dispatch_source_set_timer(logStoreTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(logStoreTimer, ^{
            if (@available(iOS 15.0, macOS 12.0, *)) pollLogStore();
        });
        dispatch_resume(logStoreTimer);
    }
}
