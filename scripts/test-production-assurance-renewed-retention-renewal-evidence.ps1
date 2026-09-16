[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidencePath,
    [string]$PlanPath = '',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedProductionContext,
    [string]$ReferenceTimeUtc = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localStateRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.shieldward'))
$localStatePrefix = $localStateRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar,[System.IO.Path]::AltDirectorySeparatorChar)+[System.IO.Path]::DirectorySeparatorChar

function Resolve-LocalStatePath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Description)
    if([string]::IsNullOrWhiteSpace($Path)){throw "$Description must not be empty."}
    $resolved=if([System.IO.Path]::IsPathRooted($Path)){[System.IO.Path]::GetFullPath($Path)}else{[System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))}
    if(-not $resolved.StartsWith($localStatePrefix,[StringComparison]::OrdinalIgnoreCase)){throw "$Description must be beneath the ignored .shieldward directory."}
    return $resolved
}

function Assert-Reference {
    param([Parameter(Mandatory)][string]$Value,[Parameter(Mandatory)][string]$Description)
    if([string]::IsNullOrWhiteSpace($Value)-or $Value.Length -gt 256-or $Value -match '[\x00-\x1f]'-or $Value -match '(?i)REPLACE'){throw "$Description must be a non-placeholder value of at most 256 characters without control characters."}
}

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Text)
    $sha256=[System.Security.Cryptography.SHA256]::Create()
    try{return ([Convert]::ToHexString($sha256.ComputeHash([System.Text.UTF8Encoding]::new($false).GetBytes($Text)))).ToLowerInvariant()}finally{$sha256.Dispose()}
}

function Test-JsonEqual {
    param([Parameter(Mandatory)]$Left,[Parameter(Mandatory)]$Right)
    return (($Left|ConvertTo-Json -Depth 9 -Compress)-eq($Right|ConvertTo-Json -Depth 9 -Compress))
}

$referenceNow=[DateTimeOffset]::UtcNow
if(-not[string]::IsNullOrWhiteSpace($ReferenceTimeUtc)){
    if($ExpectedProductionContext-ne'production-contract'){throw 'ReferenceTimeUtc is available only to the synthetic production-contract test context.'}
    $referenceNow=([DateTimeOffset]$ReferenceTimeUtc).ToUniversalTime()
}

$resolvedEvidencePath=Resolve-LocalStatePath -Path $EvidencePath -Description 'EvidencePath'
if(-not(Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)){throw "Renewed retention-renewal evidence is missing: $resolvedEvidencePath"}
$evidence=Get-Content -Raw -LiteralPath $resolvedEvidencePath|ConvertFrom-Json
if([int]$evidence.schemaVersion-ne 1-or[string]$evidence.environment-ne'production'-or[string]$evidence.evidenceType-ne'production-assurance-renewed-retention-renewal-evidence'){
    throw 'The supplied renewed retention-renewal execution evidence is unsupported.'
}
if([string]$evidence.productionContext-ne$ExpectedProductionContext-or[string]$evidence.namespace-ne'shieldward'){throw 'The renewed retention-renewal evidence targets the wrong context or namespace.'}

$resolvedPlanPath=if([string]::IsNullOrWhiteSpace($PlanPath)){Resolve-LocalStatePath -Path ([string]$evidence.approvedPlan.relativePath)-Description 'Recorded approved plan path'}else{Resolve-LocalStatePath -Path $PlanPath -Description 'PlanPath'}
if(-not(Test-Path -LiteralPath $resolvedPlanPath -PathType Leaf)){throw "Recorded approved renewed retention-renewal plan is missing: $resolvedPlanPath"}
$planValidationArguments=@{PlanPath=$resolvedPlanPath;ExpectedProductionContext=$ExpectedProductionContext;RequiredState='Approved'}
if(-not[string]::IsNullOrWhiteSpace($ReferenceTimeUtc)){$planValidationArguments.ReferenceTimeUtc=$ReferenceTimeUtc}
& (Join-Path $PSScriptRoot 'test-production-assurance-renewed-retention-renewal-plan.ps1') @planValidationArguments 6>$null

$plan=Get-Content -Raw -LiteralPath $resolvedPlanPath|ConvertFrom-Json
$planHash=(Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
$planRelativePath=[System.IO.Path]::GetRelativePath($repoRoot,$resolvedPlanPath).Replace('\','/')
$approvedAt=([DateTimeOffset]$plan.approval.approvedAtUtc).ToUniversalTime()
if($planRelativePath-ne[string]$evidence.approvedPlan.relativePath-or$planHash-ne[string]$evidence.approvedPlan.sha256-or[string]$plan.integrityDigest-ne[string]$evidence.approvedPlan.integrityDigest-or[string]$plan.approval.approvalDigest-ne[string]$evidence.approvedPlan.approvalDigest-or$approvedAt.ToString('o')-ne([DateTimeOffset]$evidence.approvedPlan.approvedAtUtc).ToUniversalTime().ToString('o')-or[string]$evidence.approvedPlan.state-ne'approved'-or[string]$evidence.approvedPlan.nextAction-ne'execute-approved-external-renewed-retention-renewal'){
    throw 'The exact approved renewed retention-renewal plan no longer matches the execution evidence.'
}
if([string]$evidence.changeId-ne[string]$plan.changeId-or[string]$evidence.incidentId-ne[string]$plan.incidentId-or[string]$evidence.closureChangeId-ne[string]$plan.closureChangeId-or-not(Test-JsonEqual -Left $evidence.candidate -Right $plan.candidate)-or-not(Test-JsonEqual -Left $evidence.lineage -Right $plan.lineage)){
    throw 'The renewed retention-renewal evidence changed the production identity or inherited lineage.'
}

$statusContracts=@(
    [pscustomobject]@{Name='external change';Actual=[string]$evidence.execution.externalChangeStatus;Allowed=@('completed','failed','unknown')}
    [pscustomobject]@{Name='retention policy';Actual=[string]$evidence.controls.retentionPolicy;Allowed=@('active','inactive','unknown')}
    [pscustomobject]@{Name='object lock';Actual=[string]$evidence.controls.objectLock;Allowed=@('enforced','not-enforced','unknown')}
    [pscustomobject]@{Name='archive inventory';Actual=[string]$evidence.controls.archiveInventory;Allowed=@('complete','incomplete','unknown')}
    [pscustomobject]@{Name='encryption';Actual=[string]$evidence.controls.encryption;Allowed=@('verified','failed','unknown')}
    [pscustomobject]@{Name='access control';Actual=[string]$evidence.controls.accessControl;Allowed=@('least-privilege','overbroad','unknown')}
    [pscustomobject]@{Name='restore verification';Actual=[string]$evidence.controls.restoreVerification;Allowed=@('passed','failed','unknown')}
)
foreach($status in $statusContracts){if($status.Allowed-notcontains$status.Actual){throw "The renewed retention-renewal evidence contains unsupported $($status.Name) status '$($status.Actual)'."}}
foreach($reference in @(
    [pscustomobject]@{Value=[string]$evidence.externalEvidence.externalChangeReference;Description='External change reference'}
    [pscustomobject]@{Value=[string]$evidence.externalEvidence.retentionPolicyReference;Description='Retention policy reference'}
    [pscustomobject]@{Value=[string]$evidence.externalEvidence.objectLockReference;Description='Object lock reference'}
    [pscustomobject]@{Value=[string]$evidence.externalEvidence.archiveInventoryReference;Description='Archive inventory reference'}
    [pscustomobject]@{Value=[string]$evidence.externalEvidence.encryptionReference;Description='Encryption reference'}
    [pscustomobject]@{Value=[string]$evidence.externalEvidence.accessReviewReference;Description='Access review reference'}
    [pscustomobject]@{Value=[string]$evidence.externalEvidence.restoreTestReference;Description='Restore test reference'}
    [pscustomobject]@{Value=[string]$evidence.externalEvidence.executedBy;Description='Executed by'}
    [pscustomobject]@{Value=[string]$evidence.externalEvidence.verifiedBy;Description='Verified by'}
)){Assert-Reference -Value $reference.Value -Description $reference.Description}

$executionCompletedAt=([DateTimeOffset]$evidence.execution.completedAtUtc).ToUniversalTime()
$collectedAt=([DateTimeOffset]$evidence.collectedAtUtc).ToUniversalTime()
$currentRetentionUntil=([DateTimeOffset]$plan.renewal.currentRetentionUntilUtc).ToUniversalTime()
$requestedRetentionUntil=([DateTimeOffset]$plan.renewal.requestedRetentionUntilUtc).ToUniversalTime()
$observedRetentionUntil=([DateTimeOffset]$evidence.renewal.observedRetentionUntilUtc).ToUniversalTime()
$nextReviewDueAt=([DateTimeOffset]$plan.renewal.nextReviewDueAtUtc).ToUniversalTime()
$minimumRemainingDays=[int]$plan.renewal.minimumRemainingDaysAfterNextReview
$remainingDaysAfterNextReview=[math]::Round(($observedRetentionUntil-$nextReviewDueAt).TotalDays,6)
$retentionExtended=$observedRetentionUntil-gt$currentRetentionUntil
$observedMeetsApprovedBoundary=$observedRetentionUntil-ge$requestedRetentionUntil
$observedCoversNextReview=$remainingDaysAfterNextReview-ge$minimumRemainingDays
$planAgeAtCollection=$collectedAt-([DateTimeOffset]$plan.generatedAtUtc).ToUniversalTime()
$executionAgeAtCollection=$collectedAt-$executionCompletedAt
if($executionCompletedAt-lt$approvedAt-or$executionCompletedAt-ge$currentRetentionUntil-or$planAgeAtCollection.TotalMinutes-lt-5-or$planAgeAtCollection.TotalMinutes-gt[int]$evidence.execution.maxApprovedPlanAgeMinutes-or$executionAgeAtCollection.TotalMinutes-lt-5-or$executionAgeAtCollection.TotalMinutes-gt[int]$evidence.execution.maxExecutionEvidenceAgeMinutes-or$referenceNow-lt$collectedAt.AddMinutes(-5)-or([DateTimeOffset]$evidence.renewal.currentRetentionUntilUtc).ToUniversalTime().ToString('o')-ne$currentRetentionUntil.ToString('o')-or([DateTimeOffset]$evidence.renewal.requestedRetentionUntilUtc).ToUniversalTime().ToString('o')-ne$requestedRetentionUntil.ToString('o')-or([DateTimeOffset]$evidence.renewal.nextReviewDueAtUtc).ToUniversalTime().ToString('o')-ne$nextReviewDueAt.ToString('o')-or[int]$evidence.renewal.minimumRemainingDaysAfterNextReview-ne$minimumRemainingDays-or[double]$evidence.renewal.remainingDaysAfterNextReview-ne$remainingDaysAfterNextReview-or[int]$evidence.renewal.currentBaselineGeneration-ne[int]$plan.renewal.currentBaselineGeneration-or[int]$evidence.renewal.nextBaselineGeneration-ne[int]$plan.renewal.nextBaselineGeneration-or[int]$evidence.renewal.currentRenewalSequence-ne[int]$plan.renewal.currentRenewalSequence-or[int]$evidence.renewal.renewalSequence-ne[int]$plan.renewal.renewalSequence){
    throw 'The renewed retention-renewal execution timing, generation, boundary, or freshness is invalid.'
}
if([bool]$evidence.renewal.retentionExtended-ne$retentionExtended-or[bool]$evidence.renewal.observedMeetsApprovedBoundary-ne$observedMeetsApprovedBoundary-or[bool]$evidence.renewal.observedCoversNextReview-ne$observedCoversNextReview){throw 'The renewed retention-renewal boundary decisions are inconsistent.'}

$hasFailure=([string]$evidence.execution.externalChangeStatus-eq'failed'-or[string]$evidence.controls.retentionPolicy-eq'inactive'-or[string]$evidence.controls.objectLock-eq'not-enforced'-or[string]$evidence.controls.archiveInventory-eq'incomplete'-or[string]$evidence.controls.encryption-eq'failed'-or[string]$evidence.controls.accessControl-eq'overbroad'-or[string]$evidence.controls.restoreVerification-eq'failed'-or-not$retentionExtended-or-not$observedMeetsApprovedBoundary-or-not$observedCoversNextReview)
$hasUnknown=@([string]$evidence.execution.externalChangeStatus,[string]$evidence.controls.retentionPolicy,[string]$evidence.controls.objectLock,[string]$evidence.controls.archiveInventory,[string]$evidence.controls.encryption,[string]$evidence.controls.accessControl,[string]$evidence.controls.restoreVerification)-contains'unknown'
$expectedOutcome=if($hasFailure){'failed'}elseif($hasUnknown){'unknown'}else{'passed'}
$expectedProven=$expectedOutcome-eq'passed'
$expectedNextAction=if([string]$evidence.execution.externalChangeStatus-eq'failed'){'retry-or-escalate-renewed-retention-renewal'}elseif([string]$evidence.controls.retentionPolicy-eq'inactive'-or[string]$evidence.controls.objectLock-eq'not-enforced'-or-not$retentionExtended-or-not$observedMeetsApprovedBoundary-or-not$observedCoversNextReview){'quarantine-and-repair-renewed-retention'}elseif([string]$evidence.controls.archiveInventory-eq'incomplete'){'restore-evidence-and-investigate'}elseif([string]$evidence.controls.encryption-eq'failed'-or[string]$evidence.controls.accessControl-eq'overbroad'){'restrict-access-and-investigate'}elseif([string]$evidence.controls.restoreVerification-eq'failed'){'repair-archive-and-repeat-restore-test'}elseif($expectedOutcome-eq'unknown'){'investigate-and-refresh-evidence'}else{'establish-next-renewed-custody-review-baseline'}
if([string]$evidence.outcome-ne$expectedOutcome-or[bool]$evidence.decision.approvedPlanVerified-ne$true-or[bool]$evidence.decision.lineagePreserved-ne$true-or[bool]$evidence.decision.retentionRenewalProven-ne$expectedProven-or[string]$evidence.decision.nextAction-ne$expectedNextAction){throw 'The renewed retention-renewal outcome or action is inconsistent with recorded evidence.'}

$integrity=[ordered]@{
    planSha256=$planHash;planIntegrityDigest=[string]$plan.integrityDigest;approvalDigest=[string]$plan.approval.approvalDigest;productionContext=$ExpectedProductionContext;namespace='shieldward';changeId=[string]$plan.changeId;incidentId=[string]$plan.incidentId;closureChangeId=[string]$plan.closureChangeId;releaseVersion=[string]$plan.candidate.version;sourceTag=[string]$plan.candidate.sourceTag;controlPlaneImage=[string]$plan.candidate.controlPlaneImage;edgeImage=[string]$plan.candidate.edgeImage;policyVersion=[string]$plan.candidate.policyVersion
    renewedBaselineSha256=[string]$plan.lineage.renewedBaselineSha256;renewedBaselineIntegrityDigest=[string]$plan.lineage.renewedBaselineIntegrityDigest;renewedLineageDigest=[string]$plan.lineage.renewedLineageDigest;previousRenewalEvidenceSha256=[string]$plan.lineage.previousRenewalEvidenceSha256;previousRenewalEvidenceIntegrityDigest=[string]$plan.lineage.previousRenewalEvidenceIntegrityDigest;originalCustodySha256=[string]$plan.lineage.originalCustodySha256;originalCustodyIntegrityDigest=[string]$plan.lineage.originalCustodyIntegrityDigest;originalCustodyChainDigest=[string]$plan.lineage.originalCustodyChainDigest;priorReviewChainDigest=[string]$plan.lineage.priorReviewChainDigest;renewedReviewChainDigest=[string]$plan.lineage.renewedReviewChainDigest;renewedReviewHeadSequence=[int]$plan.lineage.renewedReviewHeadSequence
    currentBaselineGeneration=[int]$plan.renewal.currentBaselineGeneration;nextBaselineGeneration=[int]$plan.renewal.nextBaselineGeneration;currentRenewalSequence=[int]$plan.renewal.currentRenewalSequence;renewalSequence=[int]$plan.renewal.renewalSequence;currentRetentionUntilUtc=$currentRetentionUntil.ToString('o');requestedRetentionUntilUtc=$requestedRetentionUntil.ToString('o');observedRetentionUntilUtc=$observedRetentionUntil.ToString('o');nextReviewDueAtUtc=$nextReviewDueAt.ToString('o');minimumRemainingDaysAfterNextReview=$minimumRemainingDays;remainingDaysAfterNextReview=$remainingDaysAfterNextReview;retentionExtended=$retentionExtended;observedMeetsApprovedBoundary=$observedMeetsApprovedBoundary;observedCoversNextReview=$observedCoversNextReview;approvedAtUtc=$approvedAt.ToString('o');executionCompletedAtUtc=$executionCompletedAt.ToString('o');collectedAtUtc=$collectedAt.ToString('o');maxApprovedPlanAgeMinutes=[int]$evidence.execution.maxApprovedPlanAgeMinutes;maxExecutionEvidenceAgeMinutes=[int]$evidence.execution.maxExecutionEvidenceAgeMinutes
    externalChangeStatus=[string]$evidence.execution.externalChangeStatus;retentionPolicyStatus=[string]$evidence.controls.retentionPolicy;objectLockStatus=[string]$evidence.controls.objectLock;archiveInventoryStatus=[string]$evidence.controls.archiveInventory;encryptionStatus=[string]$evidence.controls.encryption;accessControlStatus=[string]$evidence.controls.accessControl;restoreVerificationStatus=[string]$evidence.controls.restoreVerification;externalChangeReference=[string]$evidence.externalEvidence.externalChangeReference;retentionPolicyReference=[string]$evidence.externalEvidence.retentionPolicyReference;objectLockReference=[string]$evidence.externalEvidence.objectLockReference;archiveInventoryReference=[string]$evidence.externalEvidence.archiveInventoryReference;encryptionReference=[string]$evidence.externalEvidence.encryptionReference;accessReviewReference=[string]$evidence.externalEvidence.accessReviewReference;restoreTestReference=[string]$evidence.externalEvidence.restoreTestReference;executedBy=[string]$evidence.externalEvidence.executedBy;verifiedBy=[string]$evidence.externalEvidence.verifiedBy;lineagePreserved=$true;renewalProven=$expectedProven;outcome=$expectedOutcome;nextAction=$expectedNextAction
}
if((Get-Sha256Text -Text ($integrity|ConvertTo-Json -Depth 4 -Compress))-ne[string]$evidence.integrityDigest){throw 'The renewed production assurance retention-renewal evidence integrity digest is invalid.'}

Write-Host "Renewed production assurance retention-renewal evidence validation passed with outcome '$expectedOutcome'."
Write-Host "Renewal sequence $($evidence.renewal.renewalSequence) observed retention through $($observedRetentionUntil.ToString('o'))."
Write-Host 'This validator is read-only and does not alter retention, archives, access, restores, or production.'
