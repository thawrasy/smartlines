An interactive bus seat map: two plus two seats with an aisle, taken, free and selected states, and a legend.

- Props: `rows`, `taken` (seat numbers), `selected` (initial selection), `legend` (three labels), `frontLabel`, `seatWord` (for accessible names).
- The vehicle geometry never mirrors in RTL (driver on the left); only the labels around it follow the language. Seats are 44px targets with numbers, so state never depends on colour alone.
