#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface FileUploadDelegate : NSObject <WKUIDelegate>
@end

@implementation FileUploadDelegate
- (void)webView:(WKWebView *)webView
runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(NSArray<NSURL *> *URLs))completionHandler
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = NO;
    openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection;

    [openPanel beginWithCompletionHandler:^(NSModalResponse result) {
        completionHandler(result == NSModalResponseOK ? openPanel.URLs : nil);
    }];
}

- (void)webView:(WKWebView *)webView
runJavaScriptAlertPanelWithMessage:(NSString *)message
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(void))completionHandler
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"VapCalcNeo";
        alert.informativeText = message.length ? message : @"Alert";
        [alert addButtonWithTitle:@"OK"];
        [NSApp activateIgnoringOtherApps:YES];
        [alert beginSheetModalForWindow:webView.window completionHandler:^(__unused NSModalResponse returnCode) {
            completionHandler();
        }];
    });
}

- (void)webView:(WKWebView *)webView
runJavaScriptConfirmPanelWithMessage:(NSString *)message
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(BOOL result))completionHandler
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"VapCalcNeo";
        alert.informativeText = message.length ? message : @"Confirm";
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];
        [NSApp activateIgnoringOtherApps:YES];
        [alert beginSheetModalForWindow:webView.window completionHandler:^(NSModalResponse returnCode) {
            completionHandler(returnCode == NSAlertFirstButtonReturn);
        }];
    });
}
@end

static NSURL *FindAppDirectory(void);
static NSNumber *Num(id value, double fallback) {
    if ([value respondsToSelector:@selector(doubleValue)]) return @([value doubleValue]);
    return @(fallback);
}
static NSString *Str(id value, NSString *fallback) {
    return [value isKindOfClass:[NSString class]] ? value : fallback;
}

@interface AppScriptBridge : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) WKWebView *webView;
@end

@implementation AppScriptBridge

- (void)handleConsoleMessage:(id)messageBody {
    if ([messageBody isKindOfClass:[NSDictionary class]]) {
        NSDictionary *body = (NSDictionary *)messageBody;
        NSString *level = Str(body[@"level"], @"log");
        NSString *message = Str(body[@"message"], @"");
        NSLog(@"[VapCalcJS][%@] %@", level, message);
        return;
    }
    NSLog(@"[VapCalcJS] %@", messageBody);
}

- (NSURL *)supportURL {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [[[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject]
                         URLByAppendingPathComponent:@"VapCalcNeo" isDirectory:YES];
    NSError *dirError = nil;
    [fm createDirectoryAtURL:appSupport withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) NSLog(@"Failed to create Application Support directory: %@", dirError);
    return appSupport;
}
- (NSURL *)stateURL { return [[self supportURL] URLByAppendingPathComponent:@"ui_state.json"]; }
- (NSURL *)legacyStateURL { return [[self supportURL] URLByAppendingPathComponent:@"state.json"]; }
- (NSURL *)legacySessionsURL { return [[self supportURL] URLByAppendingPathComponent:@"sessions_store.json"]; }
- (NSURL *)migrationMarkerURL { return [[self supportURL] URLByAppendingPathComponent:@"native_store_migration_v2.done"]; }
- (NSURL *)sessionsDirectoryURL {
    NSURL *dir = [[self supportURL] URLByAppendingPathComponent:@"sessions" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
- (NSURL *)recordsURL { return [[self sessionsDirectoryURL] URLByAppendingPathComponent:@"session_records.json"]; }

- (id)readJSONAtURL:(NSURL *)url fallback:(id)fallback {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data.length == 0) return fallback;
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || !obj) {
        NSLog(@"Failed to parse %@: %@", url.path, err);
        return fallback;
    }
    return obj;
}

- (BOOL)writeJSONObject:(id)obj toURL:(NSURL *)url {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:(obj ?: @{}) options:NSJSONWritingPrettyPrinted error:&err];
    if (!data || err) {
        NSLog(@"Failed to serialize %@: %@", url.path, err);
        return NO;
    }
    NSError *writeErr = nil;
    BOOL ok = [data writeToURL:url options:NSDataWritingAtomic error:&writeErr];
    if (!ok || writeErr) NSLog(@"Failed to write %@: %@", url.path, writeErr);
    return ok;
}

- (NSUInteger)jsonByteSizeForObject:(id)obj {
    NSData *data = [NSJSONSerialization dataWithJSONObject:(obj ?: @{}) options:0 error:nil];
    return data.length;
}

- (void)logPayloadDirection:(NSString *)direction command:(NSString *)command object:(id)obj {
    NSUInteger bytes = [self jsonByteSizeForObject:obj];
    NSLog(@"[VapCalcNative] %@ %@ payload=%lu bytes", direction, command, (unsigned long)bytes);
    if (bytes > 100 * 1024) {
        NSLog(@"[VapCalcNative][WARN] %@ %@ exceeded 100KB (%lu bytes)", direction, command, (unsigned long)bytes);
    }
}

- (NSInteger)nextRecordIDForSessions:(NSArray *)sessions {
    NSInteger maxID = 0;
    for (NSDictionary *entry in sessions) {
        NSInteger recordID = [entry[@"id"] respondsToSelector:@selector(integerValue)] ? [entry[@"id"] integerValue] : 0;
        if (recordID > maxID) maxID = recordID;
    }
    return maxID + 1;
}

- (NSInteger)nextTrialIDForSessions:(NSArray *)sessions {
    NSInteger maxID = 0;
    for (NSDictionary *entry in sessions) {
        NSInteger trialID = [entry[@"trialId"] respondsToSelector:@selector(integerValue)] ? [entry[@"trialId"] integerValue] : 0;
        if (trialID > maxID) maxID = trialID;
    }
    return maxID + 1;
}

- (NSInteger)nextActiveTrialIDForSessions:(NSArray *)sessions {
    NSInteger maxID = 0;
    for (NSDictionary *entry in sessions) {
        if ([entry[@"removed"] boolValue]) continue;
        NSInteger trialID = [entry[@"trialId"] respondsToSelector:@selector(integerValue)] ? [entry[@"trialId"] integerValue] : 0;
        if (trialID > maxID) maxID = trialID;
    }
    return maxID + 1;
}

- (BOOL)activeSessions:(NSArray *)sessions containTrialID:(NSInteger)trialID excludingRecordID:(NSInteger)recordID {
    if (trialID <= 0) return NO;
    for (NSDictionary *entry in sessions) {
        if ([entry[@"removed"] boolValue]) continue;
        NSInteger existingRecordID = [entry[@"id"] respondsToSelector:@selector(integerValue)] ? [entry[@"id"] integerValue] : 0;
        NSInteger existingTrialID = [entry[@"trialId"] respondsToSelector:@selector(integerValue)] ? [entry[@"trialId"] integerValue] : 0;
        if (recordID > 0 && existingRecordID == recordID) continue;
        if (existingTrialID == trialID) return YES;
    }
    return NO;
}

- (NSMutableDictionary *)normalizedRecordFromObject:(NSDictionary *)item
                                         fallbackID:(NSInteger)fallbackID
                                    fallbackTrialID:(NSInteger)fallbackTrialID
                                            removed:(BOOL)removedFlag {
    if (![item isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *entry = [item mutableCopy];
    NSInteger recordID = [entry[@"id"] respondsToSelector:@selector(integerValue)] ? [entry[@"id"] integerValue] : 0;
    NSInteger trialID = [entry[@"trialId"] respondsToSelector:@selector(integerValue)] ? [entry[@"trialId"] integerValue] : 0;
    entry[@"id"] = @(recordID > 0 ? recordID : fallbackID);
    entry[@"trialId"] = @(trialID > 0 ? trialID : fallbackTrialID);
    entry[@"temp"] = Num(entry[@"temp"], 0);
    entry[@"heatSoak"] = Num(entry[@"heatSoak"], 0);
    entry[@"startingMass"] = Num(entry[@"startingMass"], 0);
    entry[@"endingMass"] = Num(entry[@"endingMass"], 0);
    double startingMass = [entry[@"startingMass"] doubleValue];
    double concentrateMass = [entry[@"concentrateMass"] respondsToSelector:@selector(doubleValue)] ? [entry[@"concentrateMass"] doubleValue] : startingMass;
    double massLost = [entry[@"massLost"] respondsToSelector:@selector(doubleValue)] ? [entry[@"massLost"] doubleValue] : (concentrateMass - [entry[@"endingMass"] doubleValue]);
    double efficiency = [entry[@"efficiency"] respondsToSelector:@selector(doubleValue)] ? [entry[@"efficiency"] doubleValue] : (concentrateMass > 0 ? (massLost / concentrateMass) * 100.0 : 0.0);
    double waxMass = [entry[@"waxMass"] respondsToSelector:@selector(doubleValue)] ? [entry[@"waxMass"] doubleValue] : ((concentrateMass - startingMass) * 1000.0);
    entry[@"concentrateMass"] = @(concentrateMass);
    entry[@"massLost"] = @(massLost);
    entry[@"efficiency"] = @(efficiency);
    entry[@"waxMass"] = @(waxMass);
    entry[@"timestamp"] = Str(entry[@"timestamp"], @"").length ? entry[@"timestamp"] : [[NSDate date] description];
    entry[@"removed"] = @(removedFlag || [entry[@"removed"] boolValue]);
    if (entry[@"originalIndex"]) entry[@"originalIndex"] = Num(entry[@"originalIndex"], trialID > 0 ? trialID : fallbackTrialID);
    return entry;
}

- (NSString *)recordFingerprint:(NSDictionary *)entry {
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%@|%@|%@",
            entry[@"timestamp"] ?: @"",
            Num(entry[@"temp"], 0),
            Num(entry[@"heatSoak"], 0),
            Num(entry[@"startingMass"], 0),
            Num(entry[@"endingMass"], 0),
            Num(entry[@"concentrateMass"], 0),
            Num(entry[@"massLost"], 0),
            Num(entry[@"efficiency"], 0),
            Num(entry[@"waxMass"], 0),
            @([entry[@"removed"] boolValue])];
}

- (BOOL)record:(NSDictionary *)entry existsInSessions:(NSArray *)sessions {
    NSInteger incomingID = [entry[@"id"] respondsToSelector:@selector(integerValue)] ? [entry[@"id"] integerValue] : 0;
    NSString *fingerprint = [self recordFingerprint:entry];
    for (NSDictionary *existing in sessions) {
        NSInteger existingID = [existing[@"id"] respondsToSelector:@selector(integerValue)] ? [existing[@"id"] integerValue] : 0;
        if (incomingID > 0 && existingID == incomingID) return YES;
        if ([[self recordFingerprint:existing] isEqualToString:fingerprint]) return YES;
    }
    return NO;
}

- (NSMutableArray<NSMutableDictionary *> *)readSessions {
    id obj = [self readJSONAtURL:[self recordsURL] fallback:@[]];
    NSMutableArray *out = [NSMutableArray array];
    if (![obj isKindOfClass:[NSArray class]]) return out;
    NSInteger nextID = 1;
    NSInteger nextTrialID = 1;
    for (id item in (NSArray *)obj) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *source = (NSDictionary *)item;
        NSMutableDictionary *entry = [self normalizedRecordFromObject:source fallbackID:nextID fallbackTrialID:nextTrialID removed:[[source objectForKey:@"removed"] boolValue]];
        nextID = MAX(nextID + 1, [entry[@"id"] integerValue] + 1);
        nextTrialID = MAX(nextTrialID + 1, [entry[@"trialId"] integerValue] + 1);
        [out addObject:entry];
    }
    return out;
}

- (NSMutableArray<NSMutableDictionary *> *)compactedSessions:(NSArray *)sessions {
    NSMutableArray<NSMutableDictionary *> *out = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seenIDs = [NSMutableSet set];
    NSMutableSet<NSString *> *seenFingerprints = [NSMutableSet set];
    for (id item in sessions) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *entry = (NSDictionary *)item;
        NSNumber *recordID = [entry[@"id"] respondsToSelector:@selector(integerValue)] ? @([entry[@"id"] integerValue]) : nil;
        NSString *fingerprint = [self recordFingerprint:entry];
        if ((recordID && [seenIDs containsObject:recordID]) || (fingerprint.length && [seenFingerprints containsObject:fingerprint])) {
            continue;
        }
        if (recordID) [seenIDs addObject:recordID];
        if (fingerprint.length) [seenFingerprints addObject:fingerprint];
        [out addObject:[entry mutableCopy]];
    }
    return out;
}

- (void)writeSessions:(NSArray *)sessions {
    NSArray *compacted = [self compactedSessions:(sessions ?: @[])];
    [self writeJSONObject:compacted toURL:[self recordsURL]];
}
- (NSMutableDictionary *)readUiState {
    id obj = [self readJSONAtURL:[self stateURL] fallback:@{}];
    return [obj isKindOfClass:[NSDictionary class]] ? [obj mutableCopy] : [NSMutableDictionary dictionary];
}
- (BOOL)isForbiddenUiStateKey:(NSString *)key {
    static NSSet *forbidden = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        forbidden = [NSSet setWithArray:@[@"sessionLog", @"removedLog", @"deletedLog", @"records", @"deletedRecords"]];
    });
    return [forbidden containsObject:key ?: @""];
}

- (BOOL)containsOversizedArrayInObject:(id)obj {
    if ([obj isKindOfClass:[NSArray class]]) return [(NSArray *)obj count] > 200;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)obj allValues]) {
            if ([self containsOversizedArrayInObject:value]) return YES;
        }
    }
    return NO;
}

- (NSMutableDictionary *)sanitizedUiStateFromObject:(NSDictionary *)uiState source:(NSString *)source {
    NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
    if (![uiState isKindOfClass:[NSDictionary class]]) return sanitized;
    for (NSString *key in uiState) {
        id value = uiState[key];
        if ([self isForbiddenUiStateKey:key]) {
            NSLog(@"[VapCalcNative][ERROR] %@ contained forbidden UI-state key %@", source, key);
            continue;
        }
        if ([value isKindOfClass:[NSArray class]] && [(NSArray *)value count] > 200) {
            NSLog(@"[VapCalcNative][ERROR] %@ contained oversized array for key %@ (%lu items)", source, key, (unsigned long)[(NSArray *)value count]);
            continue;
        }
        sanitized[key] = value;
    }
    if ([self containsOversizedArrayInObject:sanitized]) {
        NSLog(@"[VapCalcNative][ERROR] %@ still contains nested arrays larger than 200 items", source);
    }
    return sanitized;
}

- (void)writeUiState:(NSDictionary *)uiState {
    [self writeJSONObject:[self sanitizedUiStateFromObject:uiState source:@"writeUiState"] toURL:[self stateURL]];
}

- (void)mergeRecordsFromArray:(NSArray *)records removed:(BOOL)removed into:(NSMutableArray *)sessions {
    NSInteger nextID = [self nextRecordIDForSessions:sessions];
    NSInteger nextTrialID = [self nextTrialIDForSessions:sessions];
    for (id item in records) {
        NSDictionary *source = [item isKindOfClass:[NSDictionary class]] ? (NSDictionary *)item : nil;
        NSMutableDictionary *entry = [self normalizedRecordFromObject:source fallbackID:nextID fallbackTrialID:nextTrialID removed:removed];
        if (!entry) continue;
        if (removed && !entry[@"originalIndex"]) entry[@"originalIndex"] = entry[@"trialId"];
        if ([self record:entry existsInSessions:sessions]) continue;
        [sessions addObject:entry];
        nextID = MAX(nextID + 1, [entry[@"id"] integerValue] + 1);
        nextTrialID = MAX(nextTrialID + 1, [entry[@"trialId"] integerValue] + 1);
    }
}

- (void)migrateLegacyStateIfNeeded {
    NSMutableArray *sessions = [self readSessions];
    NSMutableDictionary *uiState = [self readUiState];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL hasMarker = [fm fileExistsAtPath:[self migrationMarkerURL].path];
    BOOL hasNativeRecords = sessions.count > 0 || [fm fileExistsAtPath:[self recordsURL].path];

    if (hasMarker) {
        return;
    }

    if (hasNativeRecords) {
        [uiState removeObjectForKey:@"sessionLog"];
        [uiState removeObjectForKey:@"removedLog"];
        [uiState removeObjectForKey:@"deletedLog"];
        [uiState removeObjectForKey:@"records"];
        [uiState removeObjectForKey:@"deletedRecords"];
        [self writeSessions:sessions];
        [self writeUiState:uiState];
        [@"done" writeToURL:[self migrationMarkerURL] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }

    NSDictionary *legacyState = [self readJSONAtURL:[self legacyStateURL] fallback:@{}];
    id legacySessionsArray = [self readJSONAtURL:[self legacySessionsURL] fallback:@[]];

    if ([legacySessionsArray isKindOfClass:[NSArray class]]) {
        [self mergeRecordsFromArray:(NSArray *)legacySessionsArray removed:NO into:sessions];
    }

    NSArray *uiActive = [uiState[@"sessionLog"] isKindOfClass:[NSArray class]] ? uiState[@"sessionLog"] : @[];
    NSArray *uiRemoved = [uiState[@"removedLog"] isKindOfClass:[NSArray class]] ? uiState[@"removedLog"] : @[];
    [self mergeRecordsFromArray:uiActive removed:NO into:sessions];
    [self mergeRecordsFromArray:uiRemoved removed:YES into:sessions];

    if ([legacyState isKindOfClass:[NSDictionary class]]) {
        NSArray *legacyActive = [legacyState[@"sessionLog"] isKindOfClass:[NSArray class]] ? legacyState[@"sessionLog"] : @[];
        NSArray *legacyRemoved = [legacyState[@"removedLog"] isKindOfClass:[NSArray class]] ? legacyState[@"removedLog"] : @[];
        [self mergeRecordsFromArray:legacyActive removed:NO into:sessions];
        [self mergeRecordsFromArray:legacyRemoved removed:YES into:sessions];
        for (NSString *key in legacyState) {
            if (uiState[key] || [self isForbiddenUiStateKey:key]) continue;
            uiState[key] = legacyState[key];
        }
    }

    [uiState removeObjectForKey:@"sessionLog"];
    [uiState removeObjectForKey:@"removedLog"];
    [uiState removeObjectForKey:@"deletedLog"];
    [uiState removeObjectForKey:@"records"];
    [uiState removeObjectForKey:@"deletedRecords"];

    [self writeSessions:sessions];
    [self writeUiState:uiState];
    [@"done" writeToURL:[self migrationMarkerURL] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSArray *)activeSessionsFrom:(NSArray *)sessions {
    NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *bindings) {
        return ![row[@"removed"] boolValue];
    }];
    return [sessions filteredArrayUsingPredicate:p];
}
- (NSArray *)removedSessionsFrom:(NSArray *)sessions {
    NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *bindings) {
        return [row[@"removed"] boolValue];
    }];
    return [sessions filteredArrayUsingPredicate:p];
}

- (BOOL)isLikelyISO8601UTCString:(NSString *)value {
    return value.length >= 20 && [value containsString:@"T"] && [value hasSuffix:@"Z"];
}

- (NSTimeInterval)timestampValueForString:(NSString *)value {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return 0;
    static NSISO8601DateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    NSDate *date = [formatter dateFromString:value];
    if (!date) {
        static NSISO8601DateFormatter *fallbackFormatter = nil;
        static dispatch_once_t fallbackOnceToken;
        dispatch_once(&fallbackOnceToken, ^{
            fallbackFormatter = [[NSISO8601DateFormatter alloc] init];
            fallbackFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        });
        date = [fallbackFormatter dateFromString:value];
    }
    return date.timeIntervalSince1970;
}

- (NSArray *)sortedSessions:(NSArray *)sessions sort:(NSString *)sort direction:(NSString *)direction {
    NSString *key = sort.length ? sort : @"timestamp";
    BOOL desc = ![direction isEqualToString:@"asc"];
    NSArray *sorted = [sessions sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        id va = a[key]; id vb = b[key];
        NSComparisonResult result = NSOrderedSame;
        if ([key isEqualToString:@"timestamp"]) {
            NSString *sa = Str(va, @"");
            NSString *sb = Str(vb, @"");
            if ([self isLikelyISO8601UTCString:sa] && [self isLikelyISO8601UTCString:sb]) {
                result = [sa compare:sb];
            } else {
                NSTimeInterval ta = [self timestampValueForString:sa];
                NSTimeInterval tb = [self timestampValueForString:sb];
                if (ta < tb) result = NSOrderedAscending; else if (ta > tb) result = NSOrderedDescending;
            }
            if (result == NSOrderedSame) {
                NSInteger trialA = [a[@"trialId"] respondsToSelector:@selector(integerValue)] ? [a[@"trialId"] integerValue] : 0;
                NSInteger trialB = [b[@"trialId"] respondsToSelector:@selector(integerValue)] ? [b[@"trialId"] integerValue] : 0;
                if (trialA < trialB) result = NSOrderedAscending; else if (trialA > trialB) result = NSOrderedDescending;
            }
        } else {
            double da = [va respondsToSelector:@selector(doubleValue)] ? [va doubleValue] : 0;
            double db = [vb respondsToSelector:@selector(doubleValue)] ? [vb doubleValue] : 0;
            if (da < db) result = NSOrderedAscending; else if (da > db) result = NSOrderedDescending;
            if (result == NSOrderedSame) {
                NSString *sa = Str(a[@"timestamp"], @"");
                NSString *sb = Str(b[@"timestamp"], @"");
                result = [sa compare:sb];
            }
        }
        return desc ? -result : result;
    }];
    return sorted;
}

- (double)quantile:(NSArray<NSNumber *> *)vals p:(double)p {
    NSUInteger n = vals.count;
    if (n == 0) return NAN;
    if (n == 1) return [[vals objectAtIndex:0] doubleValue];
    double idx = (n - 1) * p;
    NSUInteger lo = floor(idx), hi = ceil(idx);
    double h = idx - lo;
    return (1.0 - h) * [[vals objectAtIndex:lo] doubleValue] + h * [[vals objectAtIndex:hi] doubleValue];
}

- (NSDictionary *)boxSummaryForSessions:(NSArray *)sessions {
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *e in [self activeSessionsFrom:sessions]) {
        NSNumber *t = Num(e[@"temp"], NAN);
        NSNumber *eff = Num(e[@"efficiency"], NAN);
        NSNumber *soak = Num(e[@"heatSoak"], NAN);
        if (!isfinite([t doubleValue]) || !isfinite([eff doubleValue])) continue;
        NSMutableDictionary *bucket = groups[t];
        if (!bucket) { bucket = [@{ @"eff": [NSMutableArray array], @"soak": [NSMutableArray array] } mutableCopy]; groups[t] = bucket; }
        [bucket[@"eff"] addObject:eff];
        if (isfinite([soak doubleValue])) [bucket[@"soak"] addObject:soak];
    }
    NSArray *temps = [[groups allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *labels = [NSMutableArray array];
    NSMutableArray *stats = [NSMutableArray array];
    NSMutableArray *outliers = [NSMutableArray array];
    for (NSNumber *t in temps) {
        NSString *label = [NSString stringWithFormat:@"%@°F", t];
        [labels addObject:label];
        NSArray *vals = [groups[t][@"eff"] sortedArrayUsingSelector:@selector(compare:)];
        NSArray *soaks = groups[t][@"soak"];
        double soakSum = 0; for (NSNumber *x in soaks) soakSum += [x doubleValue];
        double avgSoak = soaks.count ? soakSum / soaks.count : NAN;
        double q1 = [self quantile:vals p:0.25];
        double med = [self quantile:vals p:0.50];
        double q3 = [self quantile:vals p:0.75];
        double iqr = isfinite(q3) && isfinite(q1) ? q3 - q1 : 0;
        double lower = q1 - 1.5 * iqr, upper = q3 + 1.5 * iqr;
        double min = vals.count ? [[vals objectAtIndex:0] doubleValue] : 0;
        double max = vals.count ? [[vals lastObject] doubleValue] : 0;
        BOOL foundInlier = NO;
        for (NSNumber *v in vals) {
            double d = [v doubleValue];
            if (d >= lower && d <= upper) {
                if (!foundInlier) { min = d; foundInlier = YES; }
                max = d;
            } else {
                [outliers addObject:@{ @"x": label, @"y": @(d) }];
            }
        }
        [stats addObject:@{ @"temp": t, @"label": label, @"n": @(vals.count), @"avgHeatSoak": isfinite(avgSoak) ? @(avgSoak) : [NSNull null], @"min": @(min), @"q1": @(q1), @"median": @(med), @"q3": @(q3), @"max": @(max), @"iqr": @(iqr), @"lowerFence": @(lower), @"upperFence": @(upper) }];
    }
    return @{ @"labels": labels, @"stats": stats, @"outliers": outliers };
}

- (NSDictionary *)statsSummaryForSessions:(NSArray *)sessions {
    NSArray *active = [self activeSessionsFrom:sessions];
    if (active.count == 0) return @{ @"count": @0 };
    double effSum = 0, tempSum = 0, soakSum = 0, maxEff = -DBL_MAX;
    for (NSDictionary *e in active) {
        double eff = [Num(e[@"efficiency"], 0) doubleValue];
        effSum += eff; if (eff > maxEff) maxEff = eff;
        tempSum += [Num(e[@"temp"], 0) doubleValue];
        soakSum += [Num(e[@"heatSoak"], 0) doubleValue];
    }
    return @{ @"count": @(active.count), @"avgEfficiency": @(effSum / active.count), @"maxEfficiency": @(maxEff), @"avgTemp": @(tempSum / active.count), @"avgHeatSoak": @(soakSum / active.count) };
}

- (NSDictionary *)fieldHistoryForSessions:(NSArray *)sessions {
    NSArray *active = [self sortedSessions:[self activeSessionsFrom:sessions] sort:@"timestamp" direction:@"desc"];
    NSMutableOrderedSet *temps = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet *soaks = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *e in active) {
        if (e[@"temp"]) [temps addObject:e[@"temp"]];
        if (e[@"heatSoak"]) [soaks addObject:e[@"heatSoak"]];
    }
    return @{ @"temperature": temps.array, @"heatSoak": soaks.array };
}

- (NSArray *)removedPageFromSessions:(NSArray *)sessions limit:(NSInteger)limit {
    NSArray *removedSorted = [self sortedSessions:[self removedSessionsFrom:sessions] sort:@"timestamp" direction:@"desc"];
    NSInteger maxCount = MAX(0, MIN(limit, (NSInteger)removedSorted.count));
    return maxCount > 0 ? [removedSorted subarrayWithRange:NSMakeRange(0, maxCount)] : @[];
}

- (NSArray *)recentChartRowsFromSessions:(NSArray *)sessions limit:(NSInteger)limit {
    NSArray *recent = [self sortedSessions:[self activeSessionsFrom:sessions] sort:@"timestamp" direction:@"desc"];
    NSInteger maxCount = MAX(0, MIN(limit, (NSInteger)recent.count));
    return maxCount > 0 ? [recent subarrayWithRange:NSMakeRange(0, maxCount)] : @[];
}

- (NSDictionary *)viewPayloadWithLimit:(NSInteger)limit offset:(NSInteger)offset sort:(NSString *)sort direction:(NSString *)direction {
    [self migrateLegacyStateIfNeeded];
    NSMutableArray *sessions = [self readSessions];
    NSArray *activeSorted = [self sortedSessions:[self activeSessionsFrom:sessions] sort:sort direction:direction];
    NSInteger total = activeSorted.count;
    if (limit <= 0) limit = 100;
    if (offset < 0) offset = 0;
    if (offset >= total && total > 0) offset = MAX(0, total - limit);
    NSInteger count = MIN(limit, MAX(0, total - offset));
    NSArray *page = count > 0 ? [activeSorted subarrayWithRange:NSMakeRange(offset, count)] : @[];
    NSArray *chartPage = [self recentChartRowsFromSessions:sessions limit:420];
    NSArray *removed = [self removedPageFromSessions:sessions limit:100];
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"nativeSessionStore"] = @YES;
    payload[@"page"] = page;
    payload[@"chartLog"] = chartPage;
    payload[@"removedPage"] = removed;
    payload[@"sessionTotalCount"] = @(total);
    payload[@"boxSummary"] = [self boxSummaryForSessions:sessions];
    payload[@"statsSummary"] = [self statsSummaryForSessions:sessions];
    payload[@"fieldHistory"] = [self fieldHistoryForSessions:sessions];
    payload[@"uiState"] = [self readUiState];
    payload[@"pageOffset"] = @(offset);
    payload[@"pageSize"] = @(limit);
    NSLog(@"[VapCalcNative] getSessionPage pageSize=%ld offset=%ld total=%ld", (long)limit, (long)offset, (long)total);
    return payload;
}

- (void)sendObjectToPage:(NSDictionary *)obj function:(NSString *)functionName {
    [self logPayloadDirection:@"send" command:functionName object:obj];
    NSData *data = [NSJSONSerialization dataWithJSONObject:(obj ?: @{}) options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *js = [NSString stringWithFormat:@"window.%@(%@);", functionName, json];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"Failed JS callback %@: %@", functionName, error);
        }];
    });
}
- (void)sendRefreshWithBody:(NSDictionary *)body {
    NSInteger limit = [body[@"limit"] respondsToSelector:@selector(integerValue)] ? [body[@"limit"] integerValue] : 100;
    NSInteger offset = [body[@"offset"] respondsToSelector:@selector(integerValue)] ? [body[@"offset"] integerValue] : 0;
    NSString *sort = Str(body[@"sort"], @"timestamp");
    NSString *direction = Str(body[@"direction"], @"desc");
    [self sendObjectToPage:[self viewPayloadWithLimit:limit offset:offset sort:sort direction:direction] function:@"__vapcalcNativeRefresh"];
}

- (NSString *)csvNumberString:(id)value {
    if (![value respondsToSelector:@selector(doubleValue)]) return @"";
    double number = [value doubleValue];
    if (!isfinite(number)) return @"";
    return [NSString stringWithFormat:@"%.15g", number];
}

- (NSString *)csvForSessions:(NSArray *)sessions {
    NSMutableString *csv = [@"Trial,Temp,HeatSoak,StartingMass,EndingMass,ConcentrateMass,MassLost,Efficiency,WaxMass,Timestamp\n" mutableCopy];
    NSArray *sorted = [self sortedSessions:[self activeSessionsFrom:sessions] sort:@"timestamp" direction:@"desc"];
    for (NSDictionary *e in sorted) {
        NSString *timestamp = [Str(e[@"timestamp"], @"") stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
        [csv appendFormat:@"%@,%@,%@,%@,%@,%@,%@,%@,%@,\"%@\"\n",
         [self csvNumberString:e[@"trialId"]],
         [self csvNumberString:e[@"temp"]],
         [self csvNumberString:e[@"heatSoak"]],
         [self csvNumberString:e[@"startingMass"]],
         [self csvNumberString:e[@"endingMass"]],
         [self csvNumberString:e[@"concentrateMass"]],
         [self csvNumberString:e[@"massLost"]],
         [self csvNumberString:e[@"efficiency"]],
         [self csvNumberString:e[@"waxMass"]],
         timestamp];
    }
    return csv;
}

- (NSArray<NSString *> *)parseCSVLine:(NSString *)line {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    BOOL inQuotes = NO;
    for (NSUInteger idx = 0; idx < line.length; idx++) {
        unichar ch = [line characterAtIndex:idx];
        if (ch == '"') {
            if (inQuotes && idx + 1 < line.length && [line characterAtIndex:(idx + 1)] == '"') {
                [current appendString:@"\""];
                idx += 1;
            } else {
                inQuotes = !inQuotes;
            }
            continue;
        }
        if (ch == ',' && !inQuotes) {
            [parts addObject:[current copy]];
            [current setString:@""];
            continue;
        }
        [current appendFormat:@"%C", ch];
    }
    [parts addObject:[current copy]];
    return parts;
}

- (NSArray *)recordsFromCSVText:(NSString *)csvText {
    NSMutableArray *records = [NSMutableArray array];
    NSArray *lines = [csvText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL skippedHeader = NO;
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0) continue;
        if (!skippedHeader) {
            skippedHeader = YES;
            continue;
        }
        NSArray *parts = [self parseCSVLine:line];
        if (parts.count < 10) continue;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"trialId"] = Num([parts objectAtIndex:0], 0);
        entry[@"temp"] = Num([parts objectAtIndex:1], 0);
        entry[@"heatSoak"] = Num([parts objectAtIndex:2], 0);
        entry[@"startingMass"] = Num([parts objectAtIndex:3], 0);
        entry[@"endingMass"] = Num([parts objectAtIndex:4], 0);
        entry[@"concentrateMass"] = Num([parts objectAtIndex:5], 0);
        entry[@"massLost"] = Num([parts objectAtIndex:6], 0);
        entry[@"efficiency"] = Num([parts objectAtIndex:7], 0);
        entry[@"waxMass"] = Num([parts objectAtIndex:8], 0);
        entry[@"timestamp"] = Str([parts objectAtIndex:9], @"");
        [records addObject:entry];
    }
    return records;
}

- (void)sendImportResult:(NSDictionary *)result {
    [self sendObjectToPage:result function:@"__vapcalcNativeImportResult"];
}

- (void)runImportCSVDialogWithBody:(NSDictionary *)body {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.allowedFileTypes = @[@"csv"];
        [panel beginWithCompletionHandler:^(NSModalResponse response) {
            if (response != NSModalResponseOK || panel.URLs.count == 0) {
                [self sendImportResult:@{ @"inserted": @0, @"skipped": @0, @"errors": @[ @"Import canceled" ] }];
                return;
            }
            NSURL *fileURL = [panel.URLs objectAtIndex:0];
            NSError *readError = nil;
            NSString *csvText = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:&readError];
            if (!csvText || readError) {
                [self sendImportResult:@{ @"inserted": @0, @"skipped": @0, @"errors": @[ readError.localizedDescription ?: @"Failed to read CSV" ] }];
                return;
            }
            NSArray *records = [self recordsFromCSVText:csvText];
            NSMutableArray *sessions = [self readSessions];
            NSInteger before = sessions.count;
            NSInteger skipped = 0;
            for (NSDictionary *item in records) {
                NSInteger nextID = [self nextRecordIDForSessions:sessions];
                NSInteger nextTrialID = [self nextTrialIDForSessions:sessions];
                NSMutableDictionary *entry = [self normalizedRecordFromObject:item fallbackID:nextID fallbackTrialID:nextTrialID removed:NO];
                if (!entry) continue;
                if ([self record:entry existsInSessions:sessions]) {
                    skipped += 1;
                    continue;
                }
                [sessions addObject:entry];
            }
            [self writeSessions:sessions];
            NSInteger inserted = sessions.count - before;
            [self sendImportResult:@{ @"inserted": @(inserted), @"skipped": @(skipped), @"errors": @[] }];
            NSMutableDictionary *refreshBody = [body mutableCopy];
            refreshBody[@"offset"] = @0;
            [self sendRefreshWithBody:refreshBody];
        }];
    });
}

- (NSDictionary *)recordByUpdatingRecord:(NSDictionary *)existing patch:(NSDictionary *)patch {
    NSMutableDictionary *merged = [existing mutableCopy];
    for (NSString *key in patch) {
        if ([key isEqualToString:@"id"]) continue;
        merged[key] = patch[key];
    }
    return [self normalizedRecordFromObject:merged
                                 fallbackID:[merged[@"id"] integerValue]
                            fallbackTrialID:[merged[@"trialId"] integerValue]
                                    removed:[existing[@"removed"] boolValue]];
}

- (void)saveCSVText:(NSString *)csvText suggestedName:(NSString *)suggestedName {
    if (csvText.length == 0) return;
    NSURL *appDirURL = FindAppDirectory();
    NSURL *sessionsDirURL = [appDirURL URLByAppendingPathComponent:@"sessions" isDirectory:YES];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtURL:sessionsDirURL withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *baseName = suggestedName.length ? [suggestedName stringByDeletingPathExtension] : @"vaporizer_sessions";
    NSString *extension = suggestedName.pathExtension.length ? suggestedName.pathExtension : @"csv";
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss-SSS";
    NSString *fileName = [NSString stringWithFormat:@"%@_%@.%@", baseName, [formatter stringFromDate:[NSDate date]], extension];
    NSURL *fileURL = [sessionsDirURL URLByAppendingPathComponent:fileName];
    NSError *writeError = nil;
    BOOL wrote = [csvText writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        [alert addButtonWithTitle:@"OK"];
        alert.messageText = wrote ? @"CSV saved" : @"CSV export failed";
        alert.informativeText = wrote ? [NSString stringWithFormat:@"Saved CSV to:\n%@", fileURL.path] : (writeError.localizedDescription ?: @"Unknown error");
        [alert runModal];
    });
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"vapcalcConsole"]) {
        [self handleConsoleMessage:message.body];
        return;
    }
    if (![message.name isEqualToString:@"vapcalcNative"]) return;
    NSDictionary *body = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
    NSString *cmd = [body[@"cmd"] isKindOfClass:[NSString class]] ? body[@"cmd"] : nil;
    if (cmd.length == 0) return;
    [self logPayloadDirection:@"recv" command:cmd object:body];

    if ([cmd isEqualToString:@"loadState"] || [cmd isEqualToString:@"getSessionView"] || [cmd isEqualToString:@"getSessionPage"]) {
        NSInteger limit = [body[@"limit"] respondsToSelector:@selector(integerValue)] ? [body[@"limit"] integerValue] : 100;
        NSInteger offset = [body[@"offset"] respondsToSelector:@selector(integerValue)] ? [body[@"offset"] integerValue] : 0;
        NSDictionary *payload = [self viewPayloadWithLimit:limit offset:offset sort:Str(body[@"sort"], @"timestamp") direction:Str(body[@"direction"], @"desc")];
        [self sendObjectToPage:payload function:[cmd isEqualToString:@"loadState"] ? @"__vapcalcNativeLoad" : @"__vapcalcNativeRefresh"];
    } else if ([cmd isEqualToString:@"getSessionCount"]) {
        NSArray *active = [self activeSessionsFrom:[self readSessions]];
        [self sendObjectToPage:@{ @"count": @(active.count) } function:@"__vapcalcNativeSessionCount"];
    } else if ([cmd isEqualToString:@"getBoxplotSummary"]) {
        NSArray *sessions = [self readSessions];
        [self sendObjectToPage:[self boxSummaryForSessions:sessions] function:@"__vapcalcNativeBoxSummary"];
    } else if ([cmd isEqualToString:@"getFieldHistory"]) {
        NSArray *sessions = [self readSessions];
        NSDictionary *allHistory = [self fieldHistoryForSessions:sessions];
        NSString *field = Str(body[@"field"], @"");
        if ([field isEqualToString:@"temp"] || [field isEqualToString:@"temperature"]) {
            [self sendObjectToPage:@{ @"field": @"temperature", @"values": allHistory[@"temperature"] ?: @[] } function:@"__vapcalcNativeFieldHistory"];
        } else if ([field isEqualToString:@"heatSoak"]) {
            [self sendObjectToPage:@{ @"field": @"heatSoak", @"values": allHistory[@"heatSoak"] ?: @[] } function:@"__vapcalcNativeFieldHistory"];
        } else {
            [self sendObjectToPage:allHistory function:@"__vapcalcNativeFieldHistory"];
        }
    } else if ([cmd isEqualToString:@"saveUiState"] || [cmd isEqualToString:@"saveState"]) {
        NSDictionary *payload = [body[@"payload"] isKindOfClass:[NSDictionary class]] ? body[@"payload"] : @{};
        [self writeUiState:[self sanitizedUiStateFromObject:payload source:cmd]];
    } else if ([cmd isEqualToString:@"appendSession"]) {
        NSMutableArray *sessions = [self readSessions];
        id recordObj = [body[@"record"] isKindOfClass:[NSDictionary class]] ? body[@"record"] : @{};
        NSMutableDictionary *record = [self normalizedRecordFromObject:recordObj
                                                            fallbackID:[self nextRecordIDForSessions:sessions]
                                                       fallbackTrialID:[self nextActiveTrialIDForSessions:sessions]
                                                               removed:NO];
        if (!record) return;
        record[@"trialId"] = @([self nextActiveTrialIDForSessions:sessions]);
        if ([self record:record existsInSessions:sessions]) {
            NSLog(@"[VapCalcNative][WARN] appendSession skipped duplicate id=%@", record[@"id"]);
        } else {
            [sessions addObject:record];
        }
        [self writeSessions:sessions];
        NSMutableDictionary *refreshBody = [body mutableCopy]; refreshBody[@"offset"] = @0; [self sendRefreshWithBody:refreshBody];
    } else if ([cmd isEqualToString:@"updateSession"]) {
        NSInteger recordID = [body[@"id"] respondsToSelector:@selector(integerValue)] ? [body[@"id"] integerValue] : [body[@"trialId"] integerValue];
        NSDictionary *patch = [body[@"patch"] isKindOfClass:[NSDictionary class]] ? body[@"patch"] : ([body[@"record"] isKindOfClass:[NSDictionary class]] ? body[@"record"] : nil);
        NSMutableArray *sessions = [self readSessions];
        for (NSUInteger i = 0; i < sessions.count; i++) {
            NSDictionary *existing = [sessions objectAtIndex:i];
            NSInteger existingID = [existing[@"id"] respondsToSelector:@selector(integerValue)] ? [existing[@"id"] integerValue] : [existing[@"trialId"] integerValue];
            if (existingID == recordID) {
                sessions[i] = [[self recordByUpdatingRecord:existing patch:patch ?: @{}] mutableCopy];
                break;
            }
        }
        [self writeSessions:sessions];
        [self sendRefreshWithBody:body];
    } else if ([cmd isEqualToString:@"deleteSession"] || [cmd isEqualToString:@"restoreSession"]) {
        NSInteger recordID = [body[@"id"] respondsToSelector:@selector(integerValue)] ? [body[@"id"] integerValue] : [body[@"trialId"] integerValue];
        BOOL restore = [cmd isEqualToString:@"restoreSession"];
        NSMutableArray *sessions = [self readSessions];
        for (NSMutableDictionary *e in sessions) {
            NSInteger existingID = [e[@"id"] respondsToSelector:@selector(integerValue)] ? [e[@"id"] integerValue] : [e[@"trialId"] integerValue];
            if (existingID == recordID) {
                if (restore) {
                    NSInteger existingTrialID = [e[@"trialId"] respondsToSelector:@selector(integerValue)] ? [e[@"trialId"] integerValue] : 0;
                    if ([self activeSessions:sessions containTrialID:existingTrialID excludingRecordID:existingID]) {
                        e[@"trialId"] = @([self nextActiveTrialIDForSessions:sessions]);
                    }
                    e[@"removed"] = @NO;
                } else {
                    e[@"removed"] = @YES;
                    e[@"originalIndex"] = e[@"trialId"] ?: @(recordID);
                }
                break;
            }
        }
        [self writeSessions:sessions];
        [self sendRefreshWithBody:body];
    } else if ([cmd isEqualToString:@"importCSV"] || [cmd isEqualToString:@"importSessions"]) {
        [self runImportCSVDialogWithBody:body];
    } else if ([cmd isEqualToString:@"exportCSV"]) {
        [self saveCSVText:[self csvForSessions:[self readSessions]] suggestedName:Str(body[@"suggestedName"], @"vaporizer_sessions.csv")];
    } else if ([cmd isEqualToString:@"saveCSV"]) {
        [self saveCSVText:Str(body[@"csvText"], @"") suggestedName:Str(body[@"suggestedName"], @"vaporizer_sessions.csv")];
    } else if ([cmd isEqualToString:@"promptVapeName"]) {
        NSString *currentName = Str(body[@"currentName"], @"");
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Edit vaporizer name";
            alert.informativeText = @"Enter a new display name for this vaporizer.";
            [alert addButtonWithTitle:@"Apply"];
            [alert addButtonWithTitle:@"Cancel"];
            NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
            input.stringValue = currentName ?: @"";
            alert.accessoryView = input;
            [NSApp activateIgnoringOtherApps:YES];
            NSModalResponse response = [alert runModal];
            if (response == NSAlertFirstButtonReturn) {
                NSString *trimmed = [input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmed.length == 0) return;
                NSData *nameData = [NSJSONSerialization dataWithJSONObject:@[trimmed] options:0 error:nil];
                NSString *nameJSON = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding] ?: @"[\"\"]";
                NSString *js = [NSString stringWithFormat:@"window.__vapcalcApplyVapeName(%@[0]);", nameJSON];
                [self.webView evaluateJavaScript:js completionHandler:nil];
            }
        });
    }
}
@end

static NSURL *FindAppDirectory(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *cwd = [fm currentDirectoryPath];
    NSURL *cwdURL = [NSURL fileURLWithPath:cwd isDirectory:YES];
    if ([fm fileExistsAtPath:[[cwdURL URLByAppendingPathComponent:@"vapcalcneo05v.html"] path]]) return cwdURL;
    NSString *execPath = [[NSProcessInfo processInfo].arguments firstObject];
    if (execPath.length > 0) {
        NSString *resolvedExecPath = [execPath stringByResolvingSymlinksInPath];
        NSURL *execURL = [NSURL fileURLWithPath:[resolvedExecPath stringByDeletingLastPathComponent] isDirectory:YES];
        if ([fm fileExistsAtPath:[[execURL URLByAppendingPathComponent:@"vapcalcneo05v.html"] path]]) return execURL;
    }
    return cwdURL;
}

@interface MainWindow : NSWindow @end
@implementation MainWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

static void InstallAppMenu(void) {
    NSMenu *menubar = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"App" action:nil keyEquivalent:@""];
    [menubar addItem:appMenuItem];
    [NSApp setMainMenu:menubar];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"App"];
    NSString *appName = [[NSProcessInfo processInfo] processName] ?: @"VapCalcNeo";
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"About %@", appName] action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Hide %@", appName] action:@selector(hide:) keyEquivalent:@"h"]];
    NSMenuItem *hideOthersItem = [[NSMenuItem alloc] initWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthersItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItem:hideOthersItem];
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", appName] action:@selector(terminate:) keyEquivalent:@"q"]];
    appMenuItem.submenu = appMenu;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) FileUploadDelegate *fileDelegate;
@property (nonatomic, strong) AppScriptBridge *bridge;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSRect frame = NSMakeRect(0, 0, 1200, 800);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
    self.window = [[MainWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"VapCalcNeo";
    self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    self.window.delegate = self;
    [self.window center];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    WKWebpagePreferences *pagePrefs = [[WKWebpagePreferences alloc] init];
    pagePrefs.allowsContentJavaScript = YES;
    config.defaultWebpagePreferences = pagePrefs;
    WKUserContentController *ucc = [[WKUserContentController alloc] init];
    self.bridge = [AppScriptBridge new];
    [ucc addScriptMessageHandler:self.bridge name:@"vapcalcNative"];
    [ucc addScriptMessageHandler:self.bridge name:@"vapcalcConsole"];
    NSString *consoleBridgeScript =
    @"(function(){"
    "if(window.__vapcalcConsoleHooked)return;"
    "window.__vapcalcConsoleHooked=true;"
    "function send(level,args){"
      "try{"
        "if(!window.webkit||!window.webkit.messageHandlers||!window.webkit.messageHandlers.vapcalcConsole)return;"
        "var parts=Array.prototype.slice.call(args||[]).map(function(item){"
          "if(typeof item==='string')return item;"
          "try{return JSON.stringify(item);}catch(e){return String(item);}"
        "});"
        "window.webkit.messageHandlers.vapcalcConsole.postMessage({level:level,message:parts.join(' ')});"
      "}catch(e){}"
    "}"
    "['log','info','warn','error'].forEach(function(level){"
      "var original=console[level];"
      "console[level]=function(){send(level,arguments); if(original) return original.apply(console,arguments);};"
    "});"
    "window.addEventListener('error',function(event){"
      "send('error',['window.onerror',event.message||'',event.filename||'',event.lineno||0,event.colno||0]);"
    "});"
    "window.addEventListener('unhandledrejection',function(event){"
      "var reason=event&&event.reason;"
      "send('error',['unhandledrejection', typeof reason==='string'?reason:JSON.stringify(reason)]);"
    "});"
    "})();";
    WKUserScript *consoleScript = [[WKUserScript alloc] initWithSource:consoleBridgeScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    [ucc addUserScript:consoleScript];
    config.userContentController = ucc;
    self.webView = [[WKWebView alloc] initWithFrame:frame configuration:config];
    self.bridge.webView = self.webView;
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.fileDelegate = [[FileUploadDelegate alloc] init];
    self.webView.UIDelegate = self.fileDelegate;
    self.webView.navigationDelegate = self;
    [self.window.contentView addSubview:self.webView];

    NSURL *appDirURL = FindAppDirectory();
    NSURL *htmlURL = [appDirURL URLByAppendingPathComponent:@"vapcalcneo05v.html"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:htmlURL.path]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Could not find vapcalcneo05v.html";
        alert.informativeText = [NSString stringWithFormat:@"Looked in: %@", appDirURL.path ?: @"(unknown)"];
        [alert runModal];
        [NSApp terminate:nil];
        return;
    }
    [self.webView loadFileURL:htmlURL allowingReadAccessToURL:appDirURL];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeMainWindow];
    [self.window makeFirstResponder:self.webView];
    [NSApp activateIgnoringOtherApps:YES];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSLog(@"[VapCalcNative] WebView didFinishNavigation");
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (self.webView) [self.webView evaluateJavaScript:@"try { nativeSaveState(true); } catch (e) { console.error(e); }" completionHandler:nil];
    return NSTerminateNow;
}
- (void)windowWillClose:(NSNotification *)notification {
    if (self.webView) [self.webView evaluateJavaScript:@"try { nativeSaveState(true); } catch (e) { console.error(e); }" completionHandler:nil];
}
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        InstallAppMenu();
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app finishLaunching];
        [app run];
    }
    return 0;
}
