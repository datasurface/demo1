"""
Copyright (c) 2026 DataSurface Inc. All Rights Reserved.
Proprietary Software - See LICENSE.txt for terms.

AWS EKS runtime environment configuration for DataSurface Yellow.
PLACEHOLDER values are replaced by the setup-walkthrough-aws skill during deployment.
"""

from datasurface.dsl import ProductionStatus, \
    RuntimeEnvironment, Ecosystem, PSPDeclaration, \
    DataMilestoningStrategy
from datasurface.keys import LocationKey
from datasurface.containers import HostPortPair, PostgresDatabase
from datasurface.security import Credential, CredentialType
from datasurface.documentation import PlainTextDocumentation
from datasurface.platforms.yellow import YellowDataPlatform, YellowPlatformServiceProvider
from datasurface.platforms.yellow.aws_assembly import YellowAWSExternalAirflow3AndMergeDatabase
from datasurface.platforms.yellow.assembly import GitCacheConfig
from datasurface.repos import VersionPatternReleaseSelector, GitHubRepository, ReleaseType, VersionPatterns

# AWS configuration - replaced by setup-walkthrough-aws skill
KUB_NAME_SPACE: str = "PLACEHOLDER_NAMESPACE"
MERGE_HOST: str = "PLACEHOLDER_AURORA_ENDPOINT"
MERGE_PORT: int = 5432
MERGE_DBNAME: str = "merge_db"
AIRFLOW_HOST: str = "PLACEHOLDER_AURORA_ENDPOINT"
AIRFLOW_PORT: int = 5432
AWS_ACCOUNT_ID: str = "PLACEHOLDER_AWS_ACCOUNT_ID"
DATASURFACE_VERSION: str = "1.1.0"
AIRFLOW_SERVICE_ACCOUNT: str = "airflow-worker"


def createDemoPSP() -> YellowPlatformServiceProvider:
    # Aurora merge database
    k8s_merge_datacontainer: PostgresDatabase = PostgresDatabase(
        "K8sMergeDB",
        hostPort=HostPortPair(MERGE_HOST, MERGE_PORT),
        locations={LocationKey("MyCorp:USA/NY_1")},
        productionStatus=ProductionStatus.NOT_PRODUCTION,
        databaseName=MERGE_DBNAME
    )

    git_config: GitCacheConfig = GitCacheConfig(
        enabled=True,
        access_mode="ReadWriteMany",
        storageClass="efs-sc"
    )

    yp_assembly: YellowAWSExternalAirflow3AndMergeDatabase = YellowAWSExternalAirflow3AndMergeDatabase(
        name="Demo",
        namespace=KUB_NAME_SPACE,
        git_cache_config=git_config,
        afHostPortPair=HostPortPair(AIRFLOW_HOST, AIRFLOW_PORT),
        airflowServiceAccount=AIRFLOW_SERVICE_ACCOUNT,
        aws_account_id=AWS_ACCOUNT_ID
    )

    psp: YellowPlatformServiceProvider = YellowPlatformServiceProvider(
        "Demo_PSP",
        {LocationKey("MyCorp:USA/NY_1")},
        PlainTextDocumentation("Demo PSP"),
        gitCredential=Credential("git", CredentialType.API_TOKEN),
        mergeRW_Credential=Credential("postgres-demo-merge", CredentialType.USER_PASSWORD),
        yp_assembly=yp_assembly,
        merge_datacontainer=k8s_merge_datacontainer,
        pv_storage_class="efs-sc",
        datasurfaceDockerImage=f"registry.gitlab.com/datasurface-inc/datasurface/datasurface:v{DATASURFACE_VERSION}",
        dataPlatforms=[
            YellowDataPlatform(
                "SCD2",
                doc=PlainTextDocumentation("SCD2 Yellow DataPlatform"),
                milestoneStrategy=DataMilestoningStrategy.SCD2,
                stagingBatchesToKeep=5
            )
        ]
    )
    return psp


def createDemoRTE(ecosys: Ecosystem) -> RuntimeEnvironment:
    assert isinstance(ecosys.owningRepo, GitHubRepository)

    psp: YellowPlatformServiceProvider = createDemoPSP()
    rte: RuntimeEnvironment = ecosys.getRuntimeEnvironmentOrThrow("demo")
    rte.configure(VersionPatternReleaseSelector(
        VersionPatterns.VN_N_N + "-demo", ReleaseType.STABLE_ONLY),
        [PSPDeclaration(psp.name, rte.owningRepo)],
        productionStatus=ProductionStatus.NOT_PRODUCTION)
    rte.setPSP(psp)
    return rte
