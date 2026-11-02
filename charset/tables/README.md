# Double-byte code page tables

The files here are read with string imports by `dbwire.charset.codepage`. They
hold Windows' own conversions of the double-byte code pages, as SQL Server
2022 performs them:

| Code page | Collation used | Default character |
|---|---|---|
| 932 (Japanese, Shift-JIS) | `Japanese_BIN` | U+30FB |
| 936 (Simplified Chinese, GBK) | `Chinese_PRC_BIN` | `?` |
| 949 (Korean) | `Korean_Wansung_BIN` | `?` |
| 950 (Traditional Chinese, Big5) | `Chinese_Taiwan_Stroke_BIN` | `?` |

## Format

`cpNNN.bin`: little-endian `u16` values. First 256 for the single bytes: the
character, or 0xFFFF for a lead byte. Then 256 for each lead byte, in
increasing order: the character of each trail byte (an invalid pair gives the
default character; entry 0 is the default character too).

`cpNNN-encode.bin`: pairs of little-endian `u16` (character, bytes), sorted by
character, for the characters from U+0080 whose bytes decode back to them;
bytes below 0x100 are one byte, others `lead << 8 | trail`.

## How they were produced

Decoding, for each code page with collation `C` (every byte pair, and every
byte alone; raw bytes inserted as `binary` so that no conversion happens on the
way in):

```sql
CREATE TABLE #d (b1 int, b2 int, v varchar(2) COLLATE C);
WITH n AS (SELECT TOP 256 ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1 AS b FROM sys.all_objects)
INSERT INTO #d SELECT a.b, c.b, CAST(a.b * 256 + c.b AS binary(2)) FROM n a CROSS JOIN n c;
INSERT INTO #d SELECT b, -1, CAST(b AS binary(1)) FROM (SELECT DISTINCT b1 AS b FROM #d) x;
SELECT b1, b2, LEN(CONVERT(nvarchar(4), v) + 'x') - 1,
       UNICODE(CONVERT(nvarchar(4), v)), UNICODE(SUBSTRING(CONVERT(nvarchar(4), v), 2, 1))
FROM #d ORDER BY b1, b2;
```

Encoding (Windows' choice among duplicate byte sequences), for every BMP
character except surrogates:

```sql
WITH n AS (SELECT TOP 65536 ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1 AS c
           FROM sys.all_objects a CROSS JOIN sys.all_objects b)
SELECT c, CAST(CAST(CAST(NCHAR(c) COLLATE C AS varchar(2)) AS varbinary(2)) AS int)
FROM n WHERE c < 55296 OR c > 57343;
```

A character is kept for encoding only when its bytes decode back to it (no
"best fit" substitutes). The decoding rules were checked on all 65,536 pairs
of each page: a lead byte plus a non-zero byte is one character; a lead byte
before 0x00 gives the default character and the 0x00; a lone lead byte at the
end gives nothing. All defined characters agree with the Unicode mapping
files, except 249 of code page 950 (0xC6A1 to 0xC7FC), which Windows maps to
private-use characters.
