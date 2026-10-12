#!/usr/bin/env python3
"""P06-029: generate a many-page object-stream fixture deterministically.

Builds Tests/Fixtures/xref-many.pdf: 100 pages whose dictionaries live in
object streams (plus the shared font), with plain content streams and a
Flate cross-reference stream. Everything is assembled with exact byte
offsets in this script; rerun to regenerate (output must be byte-identical).
"""
import os
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Tests", "Fixtures", "xref-many.pdf")
PAGES = 100


def main():
    direct = []      # (number, body) written literally (body without header)
    compressed = []  # (number, body) packed into object streams
    next_number = 1

    catalog = next_number; next_number += 1
    pages_root = next_number; next_number += 1
    font = next_number; next_number += 1

    page_numbers = []
    content_numbers = []
    for _ in range(PAGES):
        page_numbers.append(next_number); next_number += 1
        content_numbers.append(next_number); next_number += 1

    direct.append(
        (catalog, b"<< /Type /Catalog /Pages 2 0 R >>"))
    kids = " ".join("%d 0 R" % n for n in page_numbers)
    direct.append((
        pages_root,
        ("<< /Type /Pages /Count %d /Kids [%s] >>" % (PAGES, kids)).encode()))
    compressed.append((
        font, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"))
    for page, content in zip(page_numbers, content_numbers):
        compressed.append((
            page,
            ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
             "/Resources << /Font << /F1 3 0 R >> >> /Contents %d 0 R >>"
             % content).encode()))
    for index, content in enumerate(content_numbers, start=1):
        body = ("BT /F1 12 Tf 42 700 Td (Object-stream fixture - page %d) Tj ET\n"
                % index).encode()
        direct.append((
            content,
            b"<< /Length %d >>\nstream\n" % len(body) + body + b"endstream"))

    file_parts = [b"%PDF-1.7\n", bytes([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])]
    offsets = {}

    def emit(number, body):
        offsets[number] = sum(len(part) for part in file_parts)
        file_parts.append(("%d 0 obj\n" % number).encode() + body
                          + b"\nendobj\n")

    for number, body in direct:
        emit(number, body)

    # Pack compressed objects into object streams of 25.
    locations = {}
    for chunk_start in range(0, len(compressed), 25):
        chunk = compressed[chunk_start:chunk_start + 25]
        stream_number = next_number
        next_number += 1
        table = "".join(
            "%d %d\n" % (num, sum(len(b) for _, b in chunk[:i]))
            for i, (num, b) in enumerate(chunk))
        payload = table.encode() + b"".join(body for _, body in chunk)
        emit(stream_number,
             ("<< /Type /ObjStm /N %d /First %d /Length %d >>\nstream\n"
              % (len(chunk), len(table), len(payload))).encode()
             + payload + b"endstream")
        for index, (num, _) in enumerate(chunk):
            locations[num] = (stream_number, index)

    xref_number = next_number
    next_number += 1
    size = next_number
    # The xref stream lists itself (type 1 at its own offset) so the entry
    # count matches Size.
    xref_offset = sum(len(part) for part in file_parts)
    offsets[xref_number] = xref_offset
    # Cross-reference stream: type 1 = direct offset, type 2 = (stream, index).
    raw = bytearray()
    raw += bytes([0]) + (0).to_bytes(4, "big") + (65535).to_bytes(2, "big")
    for number in range(1, size):
        if number in offsets:
            raw += (bytes([1]) + offsets[number].to_bytes(4, "big")
                    + (0).to_bytes(2, "big"))
        else:
            stream, index = locations[number]
            raw += (bytes([2]) + stream.to_bytes(4, "big")
                    + index.to_bytes(2, "big"))
    assert len(raw) == size * 7, (len(raw), size)
    assert len(locations) + len(offsets) == size - 1, (  # entry 0 is the free head
        len(locations), len(offsets), size)
    compressed_data = zlib.compress(bytes(raw))
    xref_body = (
        ("<< /Type /XRef /Size %d /Root 1 0 R /W [1 4 2] /Index [0 %d] "
         "/Filter /FlateDecode /Length %d >>\nstream\n" % (size, size, len(compressed_data))).encode()
        + compressed_data + b"endstream")
    file_parts.append(("%d 0 obj\n" % xref_number).encode() + xref_body
                      + b"\nendobj\n")
    file_parts.append(b"startxref\n%d\n%%%%EOF\n" % xref_offset)

    with open(OUT, "wb") as handle:
        handle.write(b"".join(file_parts))
    print("wrote %s (%d bytes)" % (OUT, sum(len(p) for p in file_parts)))


if __name__ == "__main__":
    main()
