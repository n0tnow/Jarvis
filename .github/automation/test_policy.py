import copy
import unittest
from policy import validate


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.task = {"issue": 1, "goal": "test", "allowed_paths": ["docs/result.md"], "acceptance": ["test"]}
        self.result = {"changes": [{"path": "docs/result.md", "content": "ok\n"}], "report": "Not tested"}

    def test_valid(self):
        self.assertEqual(len(validate(self.task, self.result)), 1)

    def test_scope_escalations(self):
        for path in [".github/workflows/pwn.yml", "Package.swift", "docs/../AGENTS.md", "docs/.claude/x.md", "docs/DECISIONS.md", "docs/a.sh", "/docs/a.md"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.task["allowed_paths"] = [path]
                self.result["changes"][0]["path"] = path
                validate(self.task, self.result)

    def test_unapproved_target(self):
        self.result["changes"][0]["path"] = "Sources/Other.swift"
        with self.assertRaises(ValueError):
            validate(self.task, self.result)

    def test_duplicate(self):
        self.result["changes"] *= 2
        with self.assertRaises(ValueError):
            validate(self.task, self.result)

    def test_content_limits(self):
        for content in ["\x00", "a" * 65537, "sk-ant-dummy", "-----BEGIN RSA PRIVATE KEY-----", 42]:
            with self.subTest(content=str(content)[:30]), self.assertRaises(ValueError):
                result = copy.deepcopy(self.result)
                result["changes"][0]["content"] = content
                validate(self.task, result)

    def test_extra_keys_and_empty(self):
        for changes in [[], [{"path":"docs/result.md", "content":"x", "mode":"100755"}]]:
            self.result["changes"] = changes
            with self.assertRaises(ValueError):
                validate(self.task, self.result)


if __name__ == '__main__':
    unittest.main()
