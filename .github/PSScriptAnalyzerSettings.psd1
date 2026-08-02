@{
    Severity = @('Error', 'Warning')
    IncludeRules = @(
        'PSAvoidGlobalVars'
        'PSAvoidUsingComputerNameHardcoded'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSAvoidUsingWMICmdlet'
        'PSPossibleIncorrectComparisonWithNull'
        'PSPossibleIncorrectUsageOfAssignmentOperator'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSUsePSCredentialType'
    )
}
