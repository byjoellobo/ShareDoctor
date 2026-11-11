# PSScriptAnalyzer settings (SPEC.md section 13.1).
# Every default rule applies, except these three:
@{
    ExcludeRules = @(
        # ShareDoctor is an interactive console tool, so it writes to the console on purpose.
        'PSAvoidUsingWriteHost',
        # ShareDoctor asks before each change with its own Confirm-Step (which respects -Yes).
        'PSUseShouldProcessForStateChangingFunctions',
        # Only the tests build SecureStrings from plain text.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )
}
