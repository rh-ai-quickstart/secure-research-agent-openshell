"""Tests for the Helm chart — validates templates render cleanly."""

import subprocess
from pathlib import Path

import pytest

CHART_DIR = Path(__file__).resolve().parent.parent / "chart"


@pytest.fixture(autouse=True)
def require_helm():
    """Skip if helm is not installed."""
    result = subprocess.run(["helm", "version", "--short"], capture_output=True)
    if result.returncode != 0:
        pytest.skip("helm CLI not available")


def test_helm_lint():
    """Chart passes helm lint."""
    result = subprocess.run(
        ["helm", "lint", str(CHART_DIR)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"helm lint failed:\n{result.stdout}\n{result.stderr}"


def test_helm_template_renders():
    """Chart templates render without errors."""
    result = subprocess.run(
        ["helm", "template", "test-release", str(CHART_DIR)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"helm template failed:\n{result.stdout}\n{result.stderr}"


def test_helm_template_contains_backend_service():
    """Rendered output includes the aiq-backend Service."""
    result = subprocess.run(
        ["helm", "template", "test-release", str(CHART_DIR)],
        capture_output=True,
        text=True,
    )
    assert "aiq-backend" in result.stdout


def test_helm_template_contains_ui_route():
    """Rendered output includes the UI OpenShift Route."""
    result = subprocess.run(
        ["helm", "template", "test-release", str(CHART_DIR)],
        capture_output=True,
        text=True,
    )
    assert "aiq-ui" in result.stdout


def test_helm_template_with_api_keys():
    """Chart renders cleanly when API keys are provided."""
    result = subprocess.run(
        [
            "helm",
            "template",
            "test-release",
            str(CHART_DIR),
            "--set",
            "apiKeys.nvidia=nvapi-test",
            "--set",
            "apiKeys.tavily=tvly-test",
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"helm template with keys failed:\n{result.stderr}"
