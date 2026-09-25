"""生成器转义单测（v3.31.2）——钉死第 5-8 轮审计的注入收口不回归"""
import importlib.util
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent.parent / "scripts"


def _load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


pw = _load("generate_playwright_tests")
ju = _load("generate_junit_tests")


class TestTsEscaping:
    def test_ts_str_quotes(self):
        out = pw.ts_str("x'); execSync('evil'); ('")
        assert "'" not in out.replace("\\'", "")  # 未转义的单引号不得存在

    def test_ts_str_backtick_newline(self):
        raw = "a`b" + chr(10) + "c"
        out = pw.ts_str(raw)
        # 反引号/换行必须被转义为 \` / \n——即输出中不存在「未被反斜杠前导」的原始字符
        assert chr(10) not in out
        i = out.find(chr(96))
        while i >= 0:
            assert i > 0 and out[i - 1] == chr(92), f"未转义反引号于 {i}: {out!r}"
            i = out.find(chr(96), i + 1)

    def test_ts_doc_closes_comment(self):
        out = pw.ts_doc("x */ require('evil'); /*")
        assert "*/" not in out  # 闭注释序列必须被替换

    def test_safe_feature_strips_traversal(self):
        assert "/" not in pw.safe_feature("../etc/passwd")
        assert pw.safe_feature("") != ""


class TestJavaEscaping:
    def test_java_str_double_quote(self):
        out = ju.java_str('x"); Runtime.exec("calc"); //')
        assert '"' not in out.replace('\\"', "")

    def test_java_doc_closes_comment(self):
        out = ju.java_doc("x */ evil(); /*")
        assert "*/" not in out

    def test_safe_ident_leading_digit(self):
        assert ju.safe_ident("9field")[0] == "_"
        assert ju.safe_ident("valid_name9") == "valid_name9"


class TestPascalSafety:
    def test_pw_pascal_strips_braces(self):
        out = pw._safe_pascal("x(){evil();}void y(){//")
        assert "{" not in out and "(" not in out and ";" not in out

    def test_ju_pascal_strips_meta(self):
        out = ju._safe_pascal('t1 */ Runtime.getRuntime().exec("x"); /*')
        assert "*/" not in out and '"' not in out and "(" not in out
