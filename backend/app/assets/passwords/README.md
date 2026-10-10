# Common passwords

`common.txt.gz` lists, in lower case, the passwords of 12 to 64 printable ASCII characters found in three public lists
of the passwords most used in leaks (reviews of October 2026, M-13). `security.password_problem` refuses them.
Shorter passwords are refused by length already.

Source: SecLists by Daniel Miessler, MIT License (Copyright (c) 2018 Daniel Miessler), directory
`Passwords/Common-Credentials`: `Pwdb_top-1000000.txt`, `xato-net-10-million-passwords-1000000.txt` and
`100k-most-used-passwords-NCSC.txt` (the UK National Cyber Security Centre's list). 72,957 entries, built on
10 October 2026 with:

```
cat Pwdb_top-1000000.txt xato-net-10-million-passwords-1000000.txt 100k-most-used-passwords-NCSC.txt |
  python3 -c 'import sys; print("\n".join(sorted({w.lower() for w in (l.rstrip("\r\n") for l in sys.stdin)
                                                  if 12 <= len(w) <= 64 and w.isascii() and w.isprintable()})))' |
  gzip -9 > common.txt.gz
```
