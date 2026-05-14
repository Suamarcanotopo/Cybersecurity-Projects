"""
©AngelaMos | 2026
test_peeler.py

Tests for single-layer and multi-layer decoding in peeler.py

Verifies that peel() strips one encoding layer correctly, handles
stacked encodings (base64 over hex, double base64), respects the
max_depth limit, and populates layer metadata accurately including
depth index, format, confidence, and preview strings.

Tests:
  TestSingleLayer - base64, hex, base32 single-layer peeling
  TestMultiLayer - base64+hex and double-base64 stacked encodings
  TestPeelEdgeCases - plain text input, max_depth=0, empty string, layer metadata fields

Connects to:
  peeler.py - imports peel
  encoders.py - imports encode to construct layered test inputs
  constants.py - imports EncodingFormat
"""

from base64_tool.constants import EncodingFormat
from base64_tool.encoders import encode
from base64_tool.peeler import peel


class TestSingleLayer:
    def test_peel_base64(self) -> None:
        """
        Checks that a single base64 layer is peeled and the original bytes recovered
        """
        encoded = encode(b"Hello World", EncodingFormat.BASE64)
        result = peel(encoded)
        assert result.success is True
        assert len(result.layers) == 1
        assert result.layers[0].format == EncodingFormat.BASE64
        assert result.final_output == b"Hello World"

    def test_peel_hex(self) -> None:
        """
        Checks that a single hex layer is peeled and the original bytes recovered
        """
        encoded = encode(b"Hello World", EncodingFormat.HEX)
        result = peel(encoded)
        assert result.success is True
        assert len(result.layers) >= 1
        assert result.final_output == b"Hello World"

    def test_peel_base32(self) -> None:
        """
        Checks that a single base32 layer is successfully detected and peeled
        """
        encoded = encode(b"Hello World", EncodingFormat.BASE32)
        result = peel(encoded)
        assert result.success is True
        assert len(result.layers) >= 1


class TestMultiLayer:
    def test_base64_then_hex(self) -> None:
        """
        Checks that two stacked layers (base64 inside hex) are both peeled
        """
        step1 = encode(b"secret payload", EncodingFormat.BASE64)
        step2 = encode(step1.encode("utf-8"), EncodingFormat.HEX)
        result = peel(step2)
        assert result.success is True
        assert len(result.layers) >= 2
        assert b"secret payload" in result.final_output

    def test_base64_double_encoded(self) -> None:
        """
        Checks that base64 applied twice is unwrapped through both layers
        """
        step1 = encode(b"double layer", EncodingFormat.BASE64)
        step2 = encode(step1.encode("utf-8"), EncodingFormat.BASE64)
        result = peel(step2)
        assert result.success is True
        assert len(result.layers) >= 2


class TestPeelEdgeCases:
    def test_plaintext_no_layers(self) -> None:
        """
        Checks that plain text with no encoding returns a failed peel with zero layers
        """
        result = peel("just plain text")
        assert result.success is False
        assert len(result.layers) == 0

    def test_max_depth_respected(self) -> None:
        """
        Checks that setting max_depth=0 prevents any layers from being peeled
        """
        encoded = encode(b"data", EncodingFormat.BASE64)
        result = peel(encoded, max_depth = 0)
        assert len(result.layers) == 0

    def test_empty_string(self) -> None:
        """
        Checks that an empty string results in a failed peel
        """
        result = peel("")
        assert result.success is False

    def test_layer_metadata_populated(self) -> None:
        """
        Checks that a successful peel populates depth, confidence, and preview fields
        """
        encoded = encode(b"test data", EncodingFormat.BASE64)
        result = peel(encoded)
        if result.success and result.layers:
            layer = result.layers[0]
            assert layer.depth == 1
            assert layer.confidence > 0
            assert len(layer.encoded_preview) > 0
            assert len(layer.decoded_preview) > 0
