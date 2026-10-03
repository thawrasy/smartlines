A status chip that always pairs colour, icon and word, mapped from the platform's English status codes.

- Props: `status` (CONFIRMED, PENDING, DEPARTED, CANCELLED, ALLOW, REVIEW, DENY and the other codes in the bundle), `tone` (override: green, wheat, blue, red, neutral), children (the localized label; defaults to the code).
- Green means done or valid, wheat waiting, blue in progress, red failed. The word is mandatory because green and red sit at similar lightness.
