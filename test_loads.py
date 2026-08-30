# Copyright (c) 2026 DataSurface Inc. All Rights Reserved.
# Proprietary Software - See LICENSE.txt for terms.

import unittest
from contextlib import ExitStack
from typing import Any, Optional
from unittest.mock import patch

from datasurface.dsl import Ecosystem, DataPlatform, EcosystemPipelineGraph, PlatformPipelineGraph
from datasurface.model import loadEcosystemFromEcoModule
from datasurface.validation import ValidationTree

import eco
import rte_aws
import rte_azure
import rte_demo


class TestEcosystem(unittest.TestCase):
    def test_createEcosystem(self):
        ecosys: Optional[Ecosystem]
        ecoTree: Optional[ValidationTree]
        ecosys, ecoTree = loadEcosystemFromEcoModule(".")  # Check like a PR would first.
        self.assertIsNotNone(ecosys)
        self.assertIsNotNone(ecoTree)
        assert ecoTree is not None
        assert ecosys is not None
        if ecoTree.hasErrors():
            print("Ecosystem validation failed with errors:")
            ecoTree.printTree()
            raise Exception("Ecosystem validation failed")
        else:
            print("Ecosystem validated OK")
            if ecoTree.hasWarnings():
                print("Note: There are some warnings:")
                ecoTree.printTree()

        ecosys, ecoTree = loadEcosystemFromEcoModule(".", "demo")  # demo is the runtime environment name
        self.assertIsNotNone(ecosys)
        self.assertIsNotNone(ecoTree)
        assert ecoTree is not None
        assert ecosys is not None
        if ecoTree.hasErrors():
            print("Ecosystem validation failed with errors:")
            ecoTree.printTree()
            raise Exception("Ecosystem validation failed")
        else:
            print("Ecosystem validated OK")
            if ecoTree.hasWarnings():
                print("Note: There are some warnings:")
                ecoTree.printTree()
        vTree: ValidationTree = ecosys.lintAndHydrateCaches()
        if (vTree.hasErrors()):
            print("Ecosystem validation failed with errors:")
            vTree.printTree()
            raise Exception("Ecosystem validation failed")
        else:
            print("Ecosystem validated OK")
            if vTree.hasWarnings():
                print("Note: There are some warnings:")
                vTree.printTree()
        scd4_dp: DataPlatform[Any] = ecosys.getDataPlatformOrThrow("SCD4")  # type: ignore
        self.assertIsNotNone(scd4_dp)
        graph: EcosystemPipelineGraph = ecosys.getGraph()
        self.assertIsNotNone(graph)
        scd4_root: Optional[PlatformPipelineGraph] = graph.roots.get(scd4_dp.name)
        self.assertIsNone(scd4_root)

    def test_all_starter_rte_variants_lint_with_customer_values(self):
        variants = (
            ("local", rte_demo.createDemoRTE, {}),
            (
                "aws",
                rte_aws.createDemoRTE,
                {
                    "KUB_NAME_SPACE": "demo1-aws",
                    "MERGE_HOST": "postgres.internal.example",
                    "AIRFLOW_HOST": "postgres.internal.example",
                    "AWS_ACCOUNT_ID": "123456789012",
                },
            ),
            (
                "azure",
                rte_azure.createDemoRTE,
                {
                    "KUB_NAME_SPACE": "demo1-azure",
                    "MERGE_HOST": "sql.internal.example",
                    "AIRFLOW_HOST": "postgres.internal.example",
                },
            ),
        )

        for name, rte_factory, customer_values in variants:
            with self.subTest(rte=name), ExitStack() as stack:
                module = {
                    "local": rte_demo,
                    "aws": rte_aws,
                    "azure": rte_azure,
                }[name]
                for attribute, value in customer_values.items():
                    stack.enter_context(patch.object(module, attribute, value))
                stack.enter_context(patch.object(eco, "createDemoRTE", rte_factory))

                ecosystem = eco.createEcosystem()
                lint_tree = ecosystem.lintAndHydrateCaches()
                if lint_tree.hasErrors():
                    lint_tree.printTree()
                self.assertFalse(lint_tree.hasErrors())

                psp = module.createDemoPSP()
                self.assertEqual(
                    psp.datasurfaceDockerImage,
                    "registry.gitlab.com/datasurface-inc/datasurface/datasurface:v1.15.4",
                )


if __name__ == "__main__":
    unittest.main()
