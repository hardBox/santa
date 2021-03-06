/// Copyright 2015 Google Inc. All rights reserved.
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///    http://www.apache.org/licenses/LICENSE-2.0
///
///    Unless required by applicable law or agreed to in writing, software
///    distributed under the License is distributed on an "AS IS" BASIS,
///    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
///    See the License for the specific language governing permissions and
///    limitations under the License.

#import "SNTRuleTable.h"

#import "SNTCertificate.h"
#import "SNTCodesignChecker.h"
#import "SNTRule.h"

@implementation SNTRuleTable

- (int)initializeDatabase:(FMDatabase *)db fromVersion:(int)version {
  int newVersion = 0;

  if (version < 1) {
    [db executeUpdate:@"CREATE TABLE 'rules' ("
        @"'shasum' TEXT NOT NULL, "
        @"'state' INTEGER NOT NULL, "
        @"'type' INTEGER NOT NULL, "
        @"'custommsg' TEXT"
        @")"];

    [db executeUpdate:@"CREATE VIEW binrules AS SELECT * FROM rules WHERE type=1"];
    [db executeUpdate:@"CREATE VIEW certrules AS SELECT * FROM rules WHERE type=2"];

    [db executeUpdate:@"CREATE UNIQUE INDEX rulesunique ON rules (shasum, type)"];

    // Insert the codesigning certs for the running santad and launchd into the initial database.
    // This helps prevent accidentally denying critical system components while the database
    // is empty. This 'initial database' will then be cleared on the first successful sync.
    NSString *santadSHA = [[[[SNTCodesignChecker alloc] initWithSelf] leafCertificate] SHA256];
    NSString *launchdSHA = [[[[SNTCodesignChecker alloc] initWithPID:1] leafCertificate] SHA256];
    [db executeUpdate:@"INSERT INTO rules (shasum, state, type) VALUES (?, ?, ?)",
        santadSHA, @(RULESTATE_WHITELIST), @(RULETYPE_CERT)];
    [db executeUpdate:@"INSERT INTO rules (shasum, state, type) VALUES (?, ?, ?)",
        launchdSHA, @(RULESTATE_WHITELIST), @(RULETYPE_CERT)];

    newVersion = 1;
  }

  return newVersion;
}

#pragma mark Entry Counts

- (long)ruleCount {
  __block long count = 0;
  [self inDatabase:^(FMDatabase *db) {
      count = [db longForQuery:@"SELECT COUNT(*) FROM rules"];
  }];
  return count;
}

- (long)binaryRuleCount {
  __block long count = 0;
  [self inDatabase:^(FMDatabase *db) {
      count = [db longForQuery:@"SELECT COUNT(*) FROM binrules"];
  }];
  return count;
}

- (long)certificateRuleCount {
  __block long count = 0;
  [self inDatabase:^(FMDatabase *db) {
      count = [db longForQuery:@"SELECT COUNT(*) FROM certrules"];
  }];
  return count;
}

- (SNTRule *)ruleFromResultSet:(FMResultSet *)rs {
  SNTRule *rule = [[SNTRule alloc] init];

  rule.shasum = [rs stringForColumn:@"shasum"];
  rule.type = [rs intForColumn:@"type"];
  rule.state = [rs intForColumn:@"state"];
  rule.customMsg = [rs stringForColumn:@"custommsg"];

  return rule;
}

- (SNTRule *)certificateRuleForSHA256:(NSString *)SHA256 {
  __block SNTRule *rule;

  [self inDatabase:^(FMDatabase *db) {
      FMResultSet *rs = [db executeQuery:@"SELECT * FROM certrules WHERE shasum=? LIMIT 1", SHA256];
      if ([rs next]) {
          rule = [self ruleFromResultSet:rs];
      }
      [rs close];
  }];

  return rule;
}

- (SNTRule *)binaryRuleForSHA256:(NSString *)SHA256 {
  __block SNTRule *rule;

  [self inDatabase:^(FMDatabase *db) {
      FMResultSet *rs = [db executeQuery:@"SELECT * FROM binrules WHERE shasum=? LIMIT 1", SHA256];
      if ([rs next]) {
        rule = [self ruleFromResultSet:rs];
      }
      [rs close];
  }];

  return rule;
}

#pragma mark Adding

- (BOOL)addRules:(NSArray *)rules cleanSlate:(BOOL)cleanSlate {
  __block BOOL failed = NO;

  [self inTransaction:^(FMDatabase *db, BOOL *rollback) {
      if (cleanSlate) {
        [db executeUpdate:@"DELETE FROM rules"];
      }

      for (SNTRule *rule in rules) {
        if (![rule isKindOfClass:[SNTRule class]] ||
            !rule.shasum || rule.shasum.length == 0 ||
            rule.state == RULESTATE_UNKNOWN || rule.type == RULETYPE_UNKNOWN) {
          *rollback = failed = YES;
          return;
        }

        if (rule.state == RULESTATE_REMOVE) {
          if (![db executeUpdate:@"DELETE FROM rules WHERE shasum=? AND type=?",
                  rule.shasum, @(rule.type)]) {
            *rollback = failed = YES;
            return;
          }
        } else {
          if (![db executeUpdate:@"INSERT OR REPLACE INTO rules "
                                @"(shasum, state, type, custommsg) "
                                @"VALUES (?, ?, ?, ?);",
                  rule.shasum, @(rule.state), @(rule.type), rule.customMsg]) {
            *rollback = failed = YES;
            return;
          }
        }
      }
  }];

  return !failed;
}

@end
