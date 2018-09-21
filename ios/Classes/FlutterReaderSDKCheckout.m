/*
 Copyright 2018 Square Inc.
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "FlutterReaderSDKCheckout.h"
#import "FlutterReaderSDKErrorUtilities.h"
#import "Converters/SQRDCheckoutResult+FlutterReaderSDKAdditions.h"
#import <CoreLocation/CoreLocation.h>
#import <AVFoundation/AVFoundation.h>


@interface FlutterReaderSDKCheckout ()

@property (strong, readwrite) FlutterResult checkoutResolver;

@end

// Define all the error codes and messages below
// These error codes and messages **MUST** align with iOS error codes and javascript error codes
// Search KEEP_IN_SYNC_CHECKOUT_ERROR to update all places

// Expected errors:
static NSString *const RNReaderSDKCheckoutCancelled = @"CHECKOUT_CANCELED";
static NSString *const RNReaderSDKCheckoutSdkNotAuthorized = @"CHECKOUT_SDK_NOT_AUTHORIZED";

// React native module debug error codes
static NSString *const RNReaderSDKRNCheckoutAlreadyInProgress = @"rn_checkout_already_in_progress";
static NSString *const RNReaderSDKRNCheckoutInvalidParameter = @"rn_checkout_invalid_parameter";

// react native module debug messages
static NSString *const RNReaderSDKRNMessageCheckoutAlreadyInProgress = @"A checkout operation is already in progress. Ensure that the in-progress checkout is completed before calling startCheckoutAsync again.";
static NSString *const RNReaderSDKRNMessageCheckoutInvalidParameter = @"Invalid parameter found in checkout parameters.";


@implementation FlutterReaderSDKCheckout

- (void) startCheckout:(FlutterResult)result checkoutParametersDictionary:(NSDictionary*)checkoutParametersDictionary {
    if (self.checkoutResolver != nil) {
        self.checkoutResolver([FlutterError errorWithCode:FlutterReaderSDKUsageError
                                                  message:[FlutterReaderSDKErrorUtilities createNativeModuleError:RNReaderSDKRNCheckoutAlreadyInProgress debugMessage:RNReaderSDKRNMessageCheckoutAlreadyInProgress]
                                                  details:nil]);
        return;
    }
    NSString *paramError = nil;
    if ([self validateCheckoutParameters:checkoutParametersDictionary errorMsg:&paramError] == NO) {
        NSString *paramErrorDebugMessage = [NSString stringWithFormat:@"%@ %@", RNReaderSDKRNMessageCheckoutInvalidParameter, paramError];
        self.checkoutResolver([FlutterError errorWithCode:FlutterReaderSDKUsageError
                                                  message:[FlutterReaderSDKErrorUtilities createNativeModuleError:RNReaderSDKRNCheckoutInvalidParameter debugMessage:paramErrorDebugMessage]
                                                  details:nil]);
        return;
    }
    NSDictionary *amountMoneyDictionary = checkoutParametersDictionary[@"amountMoney"];
    SQRDMoney *amountMoney = nil;
    if (amountMoneyDictionary[@"currencyCode"]) {
        amountMoney = [[SQRDMoney alloc] initWithAmount:[amountMoneyDictionary[@"amount"] longValue] currencyCode:SQRDCurrencyCodeMake(amountMoneyDictionary[@"currencyCode"])];
    } else {
        amountMoney = [[SQRDMoney alloc] initWithAmount:[amountMoneyDictionary[@"amount"] longValue]];
    }
    
    SQRDCheckoutParameters *checkoutParams = [[SQRDCheckoutParameters alloc] initWithAmountMoney:amountMoney];
    if (checkoutParametersDictionary[@"note"]) {
        checkoutParams.note = checkoutParametersDictionary[@"note"];
    }
    if (checkoutParametersDictionary[@"skipReceipt"]) {
        checkoutParams.skipReceipt = ([checkoutParametersDictionary[@"skipReceipt"] boolValue] == YES);
    }
    if (checkoutParametersDictionary[@"alwaysRequireSignature"]) {
        checkoutParams.alwaysRequireSignature = ([checkoutParametersDictionary[@"alwaysRequireSignature"] boolValue] == YES);
    }
    if (checkoutParametersDictionary[@"allowSplitTender"]) {
        checkoutParams.allowSplitTender = ([checkoutParametersDictionary[@"allowSplitTender"] boolValue] == YES);
    }
    if (checkoutParametersDictionary[@"tipSettings"]) {
        SQRDTipSettings *tipSettings = [self buildTipSettings:checkoutParametersDictionary[@"tipSettings"]];
        checkoutParams.tipSettings = tipSettings;
    }
    if (checkoutParametersDictionary[@"additionalPaymentTypes"]) {
        checkoutParams.additionalPaymentTypes = [self buildAdditionalPaymentTypes:checkoutParametersDictionary[@"additionalPaymentTypes"]];
    }
    SQRDCheckoutController *checkoutController = [[SQRDCheckoutController alloc] initWithParameters:checkoutParams delegate:self];
    
    self.checkoutResolver = result;
    UIViewController *rootViewController = UIApplication.sharedApplication.delegate.window.rootViewController;
    [checkoutController presentFromViewController:rootViewController];
}

- (void)checkoutController:(SQRDCheckoutController *)checkoutController didFinishCheckoutWithResult:(SQRDCheckoutResult *)result
{
    self.checkoutResolver([result jsonDictionary]);
    [self clearCheckoutHooks];
}

- (void)checkoutController:(SQRDCheckoutController *)checkoutController didFailWithError:(NSError *)error
{
    NSString *message = error.localizedDescription;
    NSString *debugCode = error.userInfo[SQRDErrorDebugCodeKey];
    NSString *debugMessage = error.userInfo[SQRDErrorDebugMessageKey];
    self.checkoutResolver([FlutterError errorWithCode:[self getCheckoutErrorCode:error.code]
                                              message:[FlutterReaderSDKErrorUtilities serializeErrorToJson:debugCode message:message debugMessage:debugMessage]
                                              details:nil]);
    [self clearCheckoutHooks];
}

- (void)checkoutControllerDidCancel:(SQRDCheckoutController *)checkoutController
{
    // Return transaction cancel as an error in order to align with Android implementation
    self.checkoutResolver([FlutterError errorWithCode:RNReaderSDKCheckoutCancelled
                                              message:[FlutterReaderSDKErrorUtilities createNativeModuleError:RNReaderSDKCheckoutCancelled debugMessage:@"The user canceled the transaction."]
                                              details:nil]);
    [self clearCheckoutHooks];
}

- (void)clearCheckoutHooks
{
    self.checkoutResolver = nil;
}

- (BOOL)validateCheckoutParameters:(NSDictionary *)checkoutParametersDictionary errorMsg:(NSString **)errorMsg
{
    // check types of all parameters
    if (!checkoutParametersDictionary[@"amountMoney"] || ![checkoutParametersDictionary[@"amountMoney"] isKindOfClass:[NSDictionary class]]) {
        *errorMsg = @"'amountMoney' is missing or not an object";
        return NO;
    }
    if (checkoutParametersDictionary[@"skipReceipt"] && ![checkoutParametersDictionary[@"skipReceipt"] isKindOfClass:[NSNumber class]]) {
        *errorMsg = @"'skipReceipt' is not a boolean";
        return NO;
    }
    if (checkoutParametersDictionary[@"alwaysRequireSignature"] && ![checkoutParametersDictionary[@"alwaysRequireSignature"] isKindOfClass:[NSNumber class]]) {
        *errorMsg = @"'alwaysRequireSignature' is not a boolean";
        return NO;
    }
    if (checkoutParametersDictionary[@"allowSplitTender"] && ![checkoutParametersDictionary[@"allowSplitTender"] isKindOfClass:[NSNumber class]]) {
        *errorMsg = @"'allowSplitTender' is not a boolean";
        return NO;
    }
    if (checkoutParametersDictionary[@"note"] && ![checkoutParametersDictionary[@"note"] isKindOfClass:[NSString class]]) {
        *errorMsg = @"'note' is not a string";
        return NO;
    }
    if (checkoutParametersDictionary[@"tipSettings"] && ![checkoutParametersDictionary[@"tipSettings"] isKindOfClass:[NSDictionary class]]) {
        *errorMsg = @"'tipSettings' is not an object";
        return NO;
    }
    if (checkoutParametersDictionary[@"additionalPaymentTypes"] && ![checkoutParametersDictionary[@"additionalPaymentTypes"] isKindOfClass:[NSArray class]]) {
        *errorMsg = @"'additionalPaymentTypes' is not an array";
        return NO;
    }

    // check amountMoney
    NSDictionary *amountMoney = checkoutParametersDictionary[@"amountMoney"];
    if (!amountMoney[@"amount"] || ![amountMoney[@"amount"] isKindOfClass:[NSNumber class]]) {
        *errorMsg = @"'amount' is not an integer";
        return NO;
    }
    if (amountMoney[@"currencyCode"] && ![amountMoney[@"currencyCode"] isKindOfClass:[NSString class]]) {
        *errorMsg = @"'currencyCode' is not a string";
        return NO;
    }

    // check tipSettings
    NSDictionary *tipSettings = checkoutParametersDictionary[@"tipSettings"];
    if (tipSettings != nil) {
        if ((tipSettings[@"showCustomTipField"] && ![tipSettings[@"showCustomTipField"] isKindOfClass:[NSNumber class]])) {
            *errorMsg = @"'showCustomTipField' is not a boolean";
            return NO;
        }
        if (tipSettings[@"showSeparateTipScreen"] && ![tipSettings[@"showSeparateTipScreen"] isKindOfClass:[NSNumber class]]) {
            *errorMsg = @"'showSeparateTipScreen' is not a boolean";
            return NO;
        }
        if (tipSettings[@"tipPercentages"] && ![tipSettings[@"tipPercentages"] isKindOfClass:[NSArray class]]) {
            *errorMsg = @"'tipPercentages' is not an array";
            return NO;
        }
    }

    return YES;
}

- (SQRDTipSettings *)buildTipSettings:(NSDictionary *)tipSettingConfig
{
    SQRDTipSettings *tipSettings = [SQRDTipSettings alloc];
    if (tipSettingConfig[@"showCustomTipField"]) {
        tipSettings.showCustomTipField = ([tipSettingConfig[@"showCustomTipField"] boolValue] == YES);
    }
    if (tipSettingConfig[@"showSeparateTipScreen"]) {
        tipSettings.showSeparateTipScreen = ([tipSettingConfig[@"showSeparateTipScreen"] boolValue] == YES);
    }
    if (tipSettingConfig[@"tipPercentages"]) {
        NSMutableArray *tipPercentages = [[NSMutableArray alloc] init];
        for (NSNumber *percentage in tipSettingConfig[@"tipPercentages"]) {
            [tipPercentages addObject:percentage];
        }
        tipSettings.tipPercentages = tipPercentages;
    }

    return tipSettings;
}

- (SQRDAdditionalPaymentTypes)buildAdditionalPaymentTypes:(NSArray *)additionalPaymentTypes
{
    SQRDAdditionalPaymentTypes sqrdAdditionalPaymentTypes = 0;
    for (NSString *typeName in additionalPaymentTypes) {
        if ([typeName isEqualToString:@"cash"]) {
            sqrdAdditionalPaymentTypes |= SQRDAdditionalPaymentTypeCash;
        } else if ([typeName isEqualToString:@"manual_card_entry"]) {
            sqrdAdditionalPaymentTypes |= SQRDAdditionalPaymentTypeManualCardEntry;
        } else if ([typeName isEqualToString:@"other"]) {
            sqrdAdditionalPaymentTypes |= SQRDAdditionalPaymentTypeOther;
        }
    }

    return sqrdAdditionalPaymentTypes;
}

- (NSString *)getCheckoutErrorCode:(NSInteger)nativeErrorCode
{
    NSString *errorCode = @"UNKNOWN";
    if (nativeErrorCode == SQRDCheckoutControllerErrorUsageError) {
        errorCode = FlutterReaderSDKUsageError;
    } else {
        switch (nativeErrorCode) {
            case SQRDCheckoutControllerErrorSDKNotAuthorized:
                errorCode = RNReaderSDKCheckoutSdkNotAuthorized;
                break;
        }
    }
    return errorCode;
}

@end
