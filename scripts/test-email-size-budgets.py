#!/usr/bin/env python3
"""Exercise byte measurement and fixture ceilings without email delivery."""
import importlib.util
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("email_theme", Path(__file__).parent / "test-support/assert-email-theme.py")
theme = importlib.util.module_from_spec(spec)
spec.loader.exec_module(theme)

class EmailSizeBudgets(unittest.TestCase):
    def test_decoded_html_and_image_bytes_match_exact_payloads(self):
        message = EmailMessage()
        message.set_content("plain synthetic fixture")
        html = '<html><body>synthetic \u00e9<img src="cid:fixture"></body></html>'
        message.add_alternative(html, subtype="html", charset="utf-8")
        image = bytes(range(256)) * 4
        message.get_payload()[-1].add_related(image, maintype="image", subtype="png", cid="<fixture>")
        raw = message.as_bytes(policy=policy.SMTP)
        parsed = BytesParser(policy=policy.default).parsebytes(raw)
        metrics = theme.message_size_metrics(parsed, raw)
        self.assertEqual(len((html + "\r\n").encode("utf-8")), metrics["htmlBytes"])
        self.assertEqual(len(raw), metrics["mimeBytes"])
        self.assertEqual(1, metrics["inlineImageCount"])
        self.assertEqual(len(image), metrics["largestInlineImageBytes"])
        theme.assert_fixture_size_budget(metrics)

    def test_each_fixture_budget_rejects_growth_independently(self):
        for name, maximum in theme.FIXTURE_SIZE_BUDGET.items():
            with self.subTest(metric=name):
                metrics = dict.fromkeys(theme.FIXTURE_SIZE_BUDGET, 0)
                metrics[name] = maximum
                theme.assert_fixture_size_budget(metrics)
                metrics[name] += 1
                with self.assertRaisesRegex(AssertionError, name):
                    theme.assert_fixture_size_budget(metrics)

if __name__ == "__main__":
    unittest.main()
