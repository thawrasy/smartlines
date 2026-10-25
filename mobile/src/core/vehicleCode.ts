// The movement code on a vehicle's placard (1169, N48): MS1 and 13 letters A-Z or digits 2-7. The camera reads it from
// the placard; an officer may also type it, with spaces or small letters. The same rule as the server's
// vehicle_code_shape, so a code that is not one of the platform's is refused before it is sent.
const ALPHABET = /^[A-Z2-7]+$/;

export function vehicleCode(read: string): string | null {
  const code = read.replace(/\s+/g, "").toUpperCase();
  return code.length === 16 && code.startsWith("MS1") && ALPHABET.test(code.slice(3)) ? code : null;
}
