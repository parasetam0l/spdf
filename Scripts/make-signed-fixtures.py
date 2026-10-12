#!/usr/bin/env python3
"""P30 fixture generator: signed PDFs produced with openssl as an independent
CMS producer. Outputs land in Tests/Fixtures/Signed/ and are committed; this
script only needs to run again if the fixtures change.

Usage: python3 Scripts/make-signed-fixtures.py
"""

import base64
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Tests", "Fixtures", "Signed")
CONTENTS_BYTES = 8192
CONTENTS_HEX = "0" * (CONTENTS_BYTES * 2)
SIGNING_TIME = "D:20260101120000Z"


def openssl(*args, **kwargs):
    return subprocess.run(["openssl", *args], check=True, capture_output=True, **kwargs)


def make_keys(directory):
    ca_key = os.path.join(directory, "ca.key")
    ca_pem = os.path.join(directory, "ca.pem")
    leaf_key = os.path.join(directory, "leaf.key")
    leaf_pem = os.path.join(directory, "leaf.pem")
    openssl(
        "req", "-x509", "-newkey", "rsa:2048", "-keyout", ca_key, "-out", ca_pem,
        "-days", "3650", "-nodes", "-sha256", "-subj", "/CN=sPDF Test CA/O=sPDF Editor",
    )
    csr = os.path.join(directory, "leaf.csr")
    openssl(
        "req", "-newkey", "rsa:2048", "-keyout", leaf_key, "-out", csr, "-nodes",
        "-sha256", "-subj", "/CN=sPDF Test Signer/O=sPDF Editor",
    )
    ext = os.path.join(directory, "leaf.ext")
    with open(ext, "w") as handle:
        handle.write("keyUsage=digitalSignature\nextendedKeyUsage=emailProtection\n")
    openssl(
        "x509", "-req", "-in", csr, "-CA", ca_pem, "-CAkey", ca_key,
        "-CAcreateserial", "-out", leaf_pem, "-days", "3650", "-sha256",
        "-extfile", ext,
    )
    return ca_pem, leaf_pem, leaf_key


def build_skeleton():
    """Returns (file_bytes, sig_offset, contents_start, contents_end)."""
    objects = {}
    objects[1] = b"<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R >>"
    objects[2] = b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>"
    objects[3] = (
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] "
        b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R "
        b"/Annots [7 0 R] >>"
    )
    content = b"BT /F1 14 Tf 20 100 Td (Signed fixture) Tj ET\n"
    objects[4] = (
        b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content)
    )
    objects[5] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    objects[6] = (
        b"<< /Fields [7 0 R] /SigFlags 3 >>"
    )
    objects[7] = (
        b"<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) "
        b"/Rect [20 40 200 60] /P 3 0 R /F 132 /V 8 0 R >>"
    )
    objects[8] = (
        b"<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached "
        b"/ByteRange [0 0000000000 0000000000 0000000000] "
        b"/Contents <" + CONTENTS_HEX.encode() + b"> /M (" + SIGNING_TIME.encode() + b") >>"
    )

    def assemble(sig_byte_range, contents_hex):
        body = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
        offsets = {}
        for number in sorted(objects):
            offsets[number] = len(body)
            payload = objects[number]
            if number == 8:
                text = payload.decode("latin1")
                text = re.sub(
                    r"/ByteRange \[[^\]]*\]",
                    "/ByteRange [%d %010d %010d %010d]" % sig_byte_range,
                    text,
                )
                text = re.sub(r"/Contents <[0-9A-Fa-f]*>", "/Contents <%s>" % contents_hex, text)
                payload = text.encode("latin1")
            body += b"%d 0 obj\n" % number + payload + b"\nendobj\n"
        xref_offset = len(body)
        body += b"xref\n0 %d\n" % (max(objects) + 1)
        body += b"0000000000 65535 f \n"
        for number in sorted(objects):
            body += b"%010d 00000 n \n" % offsets[number]
        body += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
            max(objects) + 1,
            xref_offset,
        )
        return bytes(body), offsets

    placeholder = (0, 0, 0, 0)
    draft, offsets = assemble(placeholder, CONTENTS_HEX)
    sig_offset = offsets[8]
    marker = draft.find(b"/Contents <", sig_offset)
    contents_start = marker + len(b"/Contents ")
    contents_end = draft.find(b">", contents_start)
    return draft, sig_offset, contents_start, contents_end


def render_signed(leaf_pem, leaf_key, digest, workdir):
    draft, sig_offset, contents_start, contents_end = build_skeleton()
    file_length = len(draft)
    byte_range = (0, contents_start, contents_end + 1, file_length - (contents_end + 1))

    def assemble(byte_range, contents_hex):
        # Reuse the layout logic by re-assembling with the same widths.
        objects = {}
        objects[1] = b"<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R >>"
        objects[2] = b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>"
        objects[3] = (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] "
            b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R "
            b"/Annots [7 0 R] >>"
        )
        content = b"BT /F1 14 Tf 20 100 Td (Signed fixture) Tj ET\n"
        objects[4] = b"<< /Length %d >>\nstream\n%s\nendstream" % (len(content), content)
        objects[5] = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        objects[6] = b"<< /Fields [7 0 R] /SigFlags 3 >>"
        objects[7] = (
            b"<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) "
            b"/Rect [20 40 200 60] /P 3 0 R /F 132 /V 8 0 R >>"
        )
        objects[8] = (
            b"<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached "
            b"/ByteRange [%d %010d %010d %010d] "
            b"/Contents <%s> /M (%s) >>"
            % (
                byte_range[0],
                byte_range[1],
                byte_range[2],
                byte_range[3],
                contents_hex.encode(),
                SIGNING_TIME.encode(),
            )
        )
        body = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
        offsets = {}
        for number in sorted(objects):
            offsets[number] = len(body)
            body += b"%d 0 obj\n" % number + objects[number] + b"\nendobj\n"
        xref_offset = len(body)
        body += b"xref\n0 %d\n" % (max(objects) + 1)
        body += b"0000000000 65535 f \n"
        for number in sorted(objects):
            body += b"%010d 00000 n \n" % offsets[number]
        body += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
            max(objects) + 1,
            xref_offset,
        )
        return bytes(body), offsets

    final, offsets = assemble(byte_range, CONTENTS_HEX)
    assert len(final) == file_length, (len(final), file_length)
    signed_bytes = final[: byte_range[1]] + final[byte_range[2]: byte_range[2] + byte_range[3]]
    signed_path = os.path.join(workdir, "signed.bin")
    with open(signed_path, "wb") as handle:
        handle.write(signed_bytes)
    signature_path = os.path.join(workdir, "signature.der")
    openssl(
        "cms", "-sign", "-binary", "-in", signed_path, "-signer", leaf_pem,
        "-inkey", leaf_key, "-outform", "DER", "-out", signature_path, "-md", digest,
    )
    with open(signature_path, "rb") as handle:
        der = handle.read()
    if len(der) * 2 > len(CONTENTS_HEX):
        raise SystemExit("reserved /Contents space is too small")
    contents_hex = der.hex() + "0" * (len(CONTENTS_HEX) - len(der) * 2)
    final, _ = assemble(byte_range, contents_hex)
    return final, offsets, byte_range


def append_incremental_update(pdf, page_object_number):
    """Appends an incremental revision that rotates the page."""
    xref_offset = pdf.rfind(b"startxref")
    previous = int(pdf[xref_offset:].split()[1])
    trailer = pdf.rfind(b"trailer")
    size_match = re.search(rb"/Size (\d+)", pdf[trailer:])
    size = int(size_match.group(1))

    body = bytearray(pdf)
    if not body.endswith(b"\n"):
        body += b"\n"
    object_offset = len(body)
    body += (
        b"%d 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] "
        b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R "
        b"/Annots [7 0 R] /Rotate 90 >>\nendobj\n" % page_object_number
    )
    new_xref = len(body)
    body += b"xref\n0 1\n0000000000 65535 f \n%d 1\n%010d 00000 n \n" % (
        page_object_number,
        object_offset,
    )
    body += b"trailer\n<< /Size %d /Root 1 0 R /Prev %d >>\nstartxref\n%d\n%%%%EOF\n" % (
        size,
        previous,
        new_xref,
    )
    return bytes(body)


def main():
    if shutil.which("openssl") is None:
        raise SystemExit("openssl is required to generate the signed fixtures")
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as workdir:
        # Keys and the PKCS#12 stay in the temporary directory: test signing
        # material is generated at test time, so no private key is committed.
        ca_pem, leaf_pem, leaf_key = make_keys(workdir)

        signed, _, _ = render_signed(leaf_pem, leaf_key, "sha256", workdir)
        with open(os.path.join(OUT, "signed-one-page.pdf"), "wb") as handle:
            handle.write(signed)

        updated = append_incremental_update(signed, 3)
        with open(os.path.join(OUT, "signed-then-updated.pdf"), "wb") as handle:
            handle.write(updated)

        sha1, _, _ = render_signed(leaf_pem, leaf_key, "sha1", workdir)
        with open(os.path.join(OUT, "signed-sha1.pdf"), "wb") as handle:
            handle.write(sha1)

    print("signed fixtures written to", OUT)


if __name__ == "__main__":
    sys.exit(main())
