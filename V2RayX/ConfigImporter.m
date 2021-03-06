//
//  ConfigImporter.m
//  V2RayX
//
//

#import "ConfigImporter.h"
#import "utilities.h"

@implementation ConfigImporter

+ (NSString*)decodeBase64String:(NSString*)encoded {
    NSData* decodedData = [[NSData alloc] initWithBase64EncodedString:encoded options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
}

+ (NSDictionary*)parseLegacySSLink:(NSString*)link {
    //http://shadowsocks.org/en/config/quick-guide.html
    @try {
        NSString* encoded = [[link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] substringFromIndex:5];
        NSString* encodedRemoveTag = [encoded componentsSeparatedByString:@"#"][0];
        NSData* decodedData = [[NSData alloc] initWithBase64EncodedString:encodedRemoveTag options:0];
        NSString* decoded = [[NSString alloc] initWithData: decodedData
                                                  encoding:NSUTF8StringEncoding];
        
        NSArray* parts = [decoded componentsSeparatedByString:@"@"];
        NSArray* server_port = [parts[1] componentsSeparatedByString:@":"];
        NSMutableArray* method_password = [[parts[0] componentsSeparatedByString:@":"] mutableCopy];
        NSString* method = method_password[0];
        [method_password removeObjectAtIndex:0];
        return @{
                 @"server":server_port[0],
                 @"server_port":server_port[1],
                 @"password": [method_password componentsJoinedByString:@":"],
                 @"method":method};
    } @catch (NSException *exception) {
        return nil;
    } @finally {
        ;
    }
}


+ (NSDictionary*)parseStandardSSLink:(NSString*)link {
    //https://shadowsocks.org/en/spec/SIP002-URI-Scheme.html
    if (![@"ss://" isEqualToString: [link substringToIndex:5]]) {
        return nil;
    }
    @try {
        NSArray* parts = [[[link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] substringFromIndex:5] componentsSeparatedByString:@"#"];
        NSString* tag = parts.count > 1 ?  [parts[1] stringByRemovingPercentEncoding]  : @"";
        NSArray* mainParts = [parts[0] componentsSeparatedByString:@"/"];
        if (mainParts.count > 1 && [mainParts[1] length] > 1) { // /?
            return nil; // do not support plugin
        }
        NSArray* userinfoAndHost = [mainParts[0] componentsSeparatedByString:@"@"];
        NSString* userinfoEncoded = userinfoAndHost[0];
        NSString* userinfoDecoded = [ConfigImporter decodeBase64String:userinfoEncoded];
        NSArray* userinfo = [userinfoDecoded componentsSeparatedByString:@":"];
        NSArray* hostInfo = [userinfoAndHost[1] componentsSeparatedByString:@":"];
        
        NSNumberFormatter* f = [[NSNumberFormatter alloc] init];
        f.numberStyle = NSNumberFormatterDecimalStyle;
        NSNumber *port = [f numberFromString:hostInfo[1]];
        if (!port) {
            return nil;
        }
        
        return @{
                 @"server":hostInfo[0],
                 @"server_port":port,
                 @"password": userinfo[1],
                 @"method":userinfo[0],
                 @"tag":tag
                 };
    } @catch (NSException *exception) {
        return nil;
    } @finally {
        ;
    }
}

+ (NSMutableDictionary*)ssOutboundFromSSLink:(NSString*)link {
    NSDictionary* parsed = [ConfigImporter parseStandardSSLink:link];
    if (parsed) {
        return [ConfigImporter ssOutboundFromSSConfig:parsed];
    } else {
        parsed = [ConfigImporter parseLegacySSLink:link];
        if (parsed) {
            return [ConfigImporter ssOutboundFromSSConfig:parsed];
        }
    }
    return nil;
}

+ (NSMutableDictionary*)ssOutboundFromSSConfig:(NSDictionary*)jsonObject {
    if (jsonObject && jsonObject[@"server"] && jsonObject[@"server_port"] && jsonObject[@"password"] && jsonObject[@"method"] && [SUPPORTED_SS_SECURITY indexOfObject:jsonObject[@"method"]] != NSNotFound) {
        NSMutableDictionary* ssOutbound =
        [@{
             @"sendThrough": @"0.0.0.0",
             @"protocol": @"shadowsocks",
             @"settings": @{
                     @"servers": @[
                             @{
                                 @"address": jsonObject[@"server"],
                                 @"port": jsonObject[@"server_port"],
                                 @"method": jsonObject[@"method"],
                                 @"password": jsonObject[@"password"],
                                 }
                             ]
                     },
             @"tag": [NSString stringWithFormat:@"%@:%@",jsonObject[@"server"],jsonObject[@"server_port"]],
             @"streamSettings": @{},
             @"mux": @{}
         } mutableDeepCopy];
        if (jsonObject[@"tag"] && [jsonObject[@"tag"] isKindOfClass:[NSString class]] && [jsonObject[@"tag"] length] ) {
            ssOutbound[@"tag"] = jsonObject[@"tag"];
        }
        if ([jsonObject[@"fast_open"] isKindOfClass:[NSNumber class]]) {
            ssOutbound[@"streamSettings"] =[@{ @"sockopt": @{
                                                       @"tcpFastOpen": jsonObject[@"fast_open"]
                                                       }} mutableDeepCopy];
        }
        return ssOutbound;
    }
    return nil;
}

+ (NSMutableDictionary*)validateRuleSet:(NSMutableDictionary*)set {
    if (![set isKindOfClass:[NSMutableDictionary class]]) {
        NSLog(@"not a mutable dictionary class, %@", [set className]);
        return nil;
    }
    if (!set[@"rules"] || ![set[@"rules"] isKindOfClass:[NSMutableArray class]] || ![set count] ) {
        NSLog(@"no rules");
        return  nil;
    }
    if (![@"0-65535" isEqualToString: [set[@"rules"] lastObject][@"port"]]) {
        NSMutableDictionary *lastRule = [@{
                                           @"type" : @"field",
                                           @"outboundTag" : @"main",
                                           @"port" : @"0-65535"
                                           } mutableDeepCopy];
        [set[@"rules"] addObject:lastRule];
    }
    NSMutableArray* ruleToRemove = [[NSMutableArray alloc] init];
    NSArray* notSupported = @[@"source", @"user", @"inboundTag", @"protocol"];
    NSArray* supported = @[@"domain", @"ip", @"network", @"port"];
    // currently, source/user/inboundTag/protocol are not supported
    for (NSMutableDictionary* aRule in set[@"rules"]) {
        [aRule removeObjectsForKeys:notSupported];
        BOOL shouldRemove = true;
        for (NSString* supportedKey in supported) {
            if (aRule[supportedKey]) {
                shouldRemove = false;
                break;
            }
        }
        if (shouldRemove) {
            [ruleToRemove addObject:aRule];
            continue;
        }
        aRule[@"type"] = @"field";
        if (!aRule[@"outboundTag"] && !aRule[@"balancerTag"]) {
            aRule[@"outboundTag"] = @"main";
        }
        if (aRule[@"outboundTag"] && aRule[@"balancerTag"]) {
            [aRule removeObjectForKey:@"balancerTag"];
        }
    }
    for (NSMutableDictionary* aRule in ruleToRemove) {
        [set[@"rules"] removeObject:aRule];
    }
    if (!set[@"name"]) {
        set[@"name"] = @"some rule set";
    }
    return set;
}

+ (NSMutableDictionary*)importFromStandardConfigFiles:(NSArray*)files {
    NSMutableDictionary* result = [@{@"vmess": @[], @"other": @[], @"rules":@[]} mutableDeepCopy];
    for (NSURL* file in files) {
        NSError* error;
        id jsonObject = [NSJSONSerialization JSONObjectWithData:
                         [NSData dataWithContentsOfURL:file] options:0 error:&error];
        if (error) continue;
        if (![jsonObject isKindOfClass:[NSDictionary class]]) continue;
        NSMutableArray* outboundJSONs = [[NSMutableArray alloc] init];
        NSMutableArray* routingJSONs = [[NSMutableArray alloc] init];
        if ([[jsonObject objectForKey:@"outbound"] isKindOfClass:[NSDictionary class]]) {
            [outboundJSONs addObject:jsonObject[@"outbound"]];
        }
        if ([[jsonObject objectForKey:@"outboundDetour"] isKindOfClass:[NSArray class]]) {
            [outboundJSONs addObjectsFromArray:jsonObject[@"outboundDetour"]];
        }
        if ([[jsonObject objectForKey:@"outbounds"] isKindOfClass:[NSArray class]]) {
            [outboundJSONs addObjectsFromArray:jsonObject[@"outbounds"]];
        }
        for (NSDictionary* outboundJSON in outboundJSONs) {
            NSString* protocol = outboundJSON[@"protocol"];
            if (!protocol) {
                continue;
            }
            if ([@"vmess" isEqualToString:outboundJSON[@"protocol"]]) {
                [result[@"vmess"] addObject:[ServerProfile profilesFromJson:outboundJSON][0]];
            } else {
                [result[@"other"] addObject:outboundJSON];
            }
        }
        if ([[jsonObject objectForKey:@"routing"] isKindOfClass:[NSDictionary class]]) {
            [routingJSONs addObject:[jsonObject objectForKey:@"routing"]];
        }
        if ([[jsonObject objectForKey:@"routings"] isKindOfClass:[NSArray class]]) {
            [routingJSONs addObjectsFromArray:[jsonObject objectForKey:@"routings"]];
        }
        for (NSDictionary* routingSet in routingJSONs) {
            NSMutableDictionary* set = [routingSet mutableDeepCopy];
            if (set[@"settings"]) { // compatibal with previous config file format
                set = set[@"settings"];
            }
            NSMutableDictionary* validatedSet = [ConfigImporter validateRuleSet:set];
            if (validatedSet) {
                [result[@"rules"] addObject:validatedSet];
            }
        }
        if (jsonObject[@"server"] && jsonObject[@"server_port"] && jsonObject[@"password"] && jsonObject[@"method"] && [SUPPORTED_SS_SECURITY indexOfObject:jsonObject[@"method"]] != NSNotFound) {
            NSMutableDictionary* ssOutbound = [@{
                                                 @"sendThrough": @"0.0.0.0",
                                                 @"protocol": @"shadowsocks",
                                                 @"settings": @{
                                                         @"servers": @[
                                                                 @{
                                                                     @"address": jsonObject[@"server"],
                                                                     @"port": jsonObject[@"server_port"],
                                                                     @"method": jsonObject[@"method"],
                                                                     @"password": jsonObject[@"password"],
                                                                     }
                                                                 ]
                                                         },
                                                 @"tag": [NSString stringWithFormat:@"%@:%@",jsonObject[@"server"],jsonObject[@"server_port"]],
                                                 @"streamSettings": @{},
                                                 @"mux": @{}
                                                 } mutableDeepCopy];
            if ([jsonObject[@"fast_open"] isKindOfClass:[NSNumber class]]) {
                ssOutbound[@"streamSettings"] =[@{ @"sockopt": @{
                                                           @"tcpFastOpen": jsonObject[@"fast_open"]
                                                           }} mutableDeepCopy];
            }
            [result[@"other"] addObject:ssOutbound];
        }
    }
    return result;
}

+ (NSMutableDictionary*)importFromSubscriptionOfV2RayN: (NSString*)httpLink {
    // https://blog.csdn.net/yi_zz32/article/details/48769487
    NSMutableDictionary* result = [@{@"vmess": @[], @"other": @[]} mutableDeepCopy];
    if (![@"http" isEqualToString:[httpLink substringToIndex:4]]) {
        return nil;
    }
    NSURL *url = [NSURL URLWithString:httpLink];
    NSError *urlError = nil;
    NSString *urlStr = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&urlError];
    if (!urlError) {
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:urlStr options:0];
        if (!decodedData) {
            return [[NSMutableDictionary alloc] init];
        }
        NSString *decodedDataStr = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        decodedDataStr = [decodedDataStr stringByReplacingOccurrencesOfString:@"\r" withString:@""];
        NSArray *decodedDataArray = [decodedDataStr componentsSeparatedByString:@"\n"];
        for (id linkStr in decodedDataArray) {
            if ([linkStr length] != 0) {
                ServerProfile* p = [ConfigImporter importFromVmessOfV2RayN:linkStr];
                if (p) {
                    [result[@"vmess"] addObject:p];
                    continue;
                }
                NSMutableDictionary* outbound = [ConfigImporter ssOutboundFromSSLink:linkStr];
                if (outbound) {
                    [result[@"other"] addObject:outbound];
                    continue;
                }
            }
        }
        return result;
    }
    return [[NSMutableDictionary alloc] init];
}

+ (ServerProfile*)importFromVmessOfV2RayN:(NSString*)vmessStr {
    if ([vmessStr length] < 9 || ![[[vmessStr substringToIndex:8] lowercaseString] isEqualToString:@"vmess://"]) {
        return nil;
    }
    // https://stackoverflow.com/questions/19088231/base64-decoding-in-ios-7
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:[vmessStr substringFromIndex:8] options:0];
    if (!decodedData) {
        return nil;
    }
    NSError* jsonParseError;
    NSDictionary *sharedServer = [NSJSONSerialization JSONObjectWithData:decodedData options:0 error:&jsonParseError];
    if (jsonParseError) {
        return nil;
    }
    ServerProfile* newProfile = [[ServerProfile alloc] init];
    newProfile.outboundTag = nilCoalescing([sharedServer objectForKey:@"ps"], @"imported From QR");
    newProfile.address = nilCoalescing([sharedServer objectForKey:@"add"], @"");
    newProfile.port = [nilCoalescing([sharedServer objectForKey:@"port"], @0) intValue];
    newProfile.userId = nilCoalescing([sharedServer objectForKey:@"id"], newProfile.userId);
    newProfile.alterId = [nilCoalescing([sharedServer objectForKey:@"aid"], @0) intValue];
    NSDictionary *netWorkDict = @{@"tcp": @0, @"kcp": @1, @"ws":@2, @"h2":@3 };
    if ([sharedServer objectForKey:@"net"] && [netWorkDict objectForKey:[sharedServer objectForKey:@"net"]]) {
        newProfile.network = [netWorkDict[sharedServer[@"net"]] intValue];
    }
    NSMutableDictionary* streamSettings = [newProfile.streamSettings mutableDeepCopy];
    switch (newProfile.network) {
        case tcp:
            if (![sharedServer objectForKey:@"type"] || !([sharedServer[@"type"] isEqualToString:@"none"] || [sharedServer[@"type"] isEqualToString:@"http"])) {
                break;
            }
            streamSettings[@"tcpSettings"][@"header"][@"type"] = sharedServer[@"type"];
            if ([streamSettings[@"tcpSettings"][@"header"][@"type"] isEqualToString:@"http"]) {
                if ([sharedServer objectForKey:@"host"]) {
                    streamSettings[@"tcpSettings"][@"header"][@"host"] = [sharedServer[@"host"] componentsSeparatedByString:@","];
                }
            }
            break;
        case kcp:
            if (![sharedServer objectForKey:@"type"]) {
                break;
            }
            if (![@{@"none": @0, @"srtp": @1, @"utp": @2, @"wechat-video":@3, @"dtls":@4, @"wireguard":@5} objectForKey:sharedServer[@"type"]]) {
                break;
            }
            streamSettings[@"kcpSettings"][@"header"][@"type"] = sharedServer[@"type"];
            break;
        case ws:
            if ([[sharedServer objectForKey:@"host"] containsString:@";"]) {
                NSArray *tempPathHostArray = [[sharedServer objectForKey:@"host"] componentsSeparatedByString:@";"];
                streamSettings[@"wsSettings"][@"path"] = tempPathHostArray[0];
                streamSettings[@"wsSettings"][@"headers"][@"Host"] = tempPathHostArray[1];
            }
            else {
                streamSettings[@"wsSettings"][@"path"] = nilCoalescing([sharedServer objectForKey:@"path"], @"");
                streamSettings[@"wsSettings"][@"headers"][@"Host"] = nilCoalescing([sharedServer objectForKey:@"host"], @"");
            }
            break;
        case http:
            if ([[sharedServer objectForKey:@"host"] containsString:@";"]) {
                NSArray *tempPathHostArray = [[sharedServer objectForKey:@"host"] componentsSeparatedByString:@";"];
                streamSettings[@"wsSettings"][@"path"] = tempPathHostArray[0];
                streamSettings[@"wsSettings"][@"headers"][@"Host"] = [tempPathHostArray[1] componentsSeparatedByString:@","];
            }
            else {
                streamSettings[@"httpSettings"][@"path"] = nilCoalescing([sharedServer objectForKey:@"path"], @"");
                if (![sharedServer objectForKey:@"host"]) {
                    break;
                };
                if ([[sharedServer objectForKey:@"host"] length] > 0) {
                    streamSettings[@"httpSettings"][@"host"] = [[sharedServer objectForKey:@"host"] componentsSeparatedByString:@","];
                }
            }
            break;
        default:
            break;
    }
    if ([sharedServer objectForKey:@"tls"] && [sharedServer[@"tls"] isEqualToString:@"tls"]) {
        streamSettings[@"security"] = @"tls";
    }
    newProfile.streamSettings = streamSettings;
    return newProfile;
}


@end
