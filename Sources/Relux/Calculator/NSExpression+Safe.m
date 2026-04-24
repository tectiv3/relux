#import "NSExpression+Safe.h"

@implementation NSExpression (Safe)

+ (nullable NSNumber *)relux_safeEvaluateExpression:(NSString *)expressionString {
    @try {
        NSExpression *expr = [NSExpression expressionWithFormat:expressionString];
        id value = [expr expressionValueWithObject:nil context:nil];
        if ([value isKindOfClass:[NSNumber class]]) {
            return value;
        }
        return nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

@end
