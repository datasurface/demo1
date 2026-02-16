"""
Copyright (c) 2026 DataSurface Inc. All Rights Reserved.
Proprietary Software - See LICENSE.txt for terms.

AWS EKS runtime environment configuration for DataSurface Yellow.
All AWS-specific values are read from environment variables so the same
file works across different AWS deployments without modification.

Required environment variables:
  MERGE_HOST       - Aurora/RDS endpoint for merge database
  AWS_ACCOUNT_ID   - 12-digit AWS account ID

Optional environment variables:
  NAMESPACE              - K8s namespace (default: demo1-aws)
  AIRFLOW_HOST           - Aurora/RDS endpoint for Airflow DB (default: same as MERGE_HOST)
  AIRFLOW_PORT           - Airflow DB port (default: 5432)
  MERGE_PORT             - Merge DB port (default: 5432)
  MERGE_DBNAME           - Merge database name (default: merge_db)
  AIRFLOW_SERVICE_ACCOUNT - Helm Airflow worker service account (default: airflow-worker)
  DATASURFACE_VERSION    - DataSurface image version (default: 1.1.0)
"""

import os

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

# AWS configuration from environment variables
KUB_NAME_SPACE: str = os.environ.get("NAMESPACE", "demo1-aws")
AIRFLOW_SERVICE_ACCOUNT: str = os.environ.get("AIRFLOW_SERVICE_ACCOUNT", "airflow-worker")
MERGE_HOST: str = os.environ["MERGE_HOST"]
MERGE_PORT: int = int(os.environ.get("MERGE_PORT", "5432"))
MERGE_DBNAME: str = os.environ.get("MERGE_DBNAME", "merge_db")
AIRFLOW_HOST: str = os.environ.get("AIRFLOW_HOST", MERGE_HOST)
AIRFLOW_PORT: int = int(os.environ.get("AIRFLOW_PORT", "5432"))
AWS_ACCOUNT_ID: str = os.environ["AWS_ACCOUNT_ID"]
DATASURFACE_VERSION: str = os.environ.get("DATASURFACE_VERSION", "1.1.0")


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
