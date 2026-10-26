"""Prints the keys a secure fuel tag (NTAG 424 DNA) is programmed with, for the platform's programming bench (1181).

    python -m app.tools.fuel_tag_keys 04DE5F1EACC040 [04A1...]     # the tags' serials, as the bench reads them

For each serial: the meta key (SDMMetaRead, the same for every tag), the tag's own file key (SDMFileRead, drawn from
its serial and MASSLAK_FUEL_TAG_KEY) and a sample message with counter 1, which the API must accept. The bench sets SUN
with the serial and counter mirrored (picc_data) and a MAC over nothing (cmac), as in NXP AN12196, then the tags are
registered in the platform's fuel page. Run on the server; the keys are printed, never logged.
"""
import sys

from ..modules.fuel import assurance

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    print("meta key (SDMMetaRead):", assurance.meta_key().hex().upper())
    for serial in sys.argv[1:]:
        uid = serial.replace(":", "").strip().upper()
        message = assurance.sun_message(uid, 1)
        assert assurance.read_sun(message) == (uid, 1)
        print(uid, "file key (SDMFileRead):", assurance.file_key(bytes.fromhex(uid)).hex().upper(), "sample:", message)
