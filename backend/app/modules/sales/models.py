"""Request models for holds and bookings. Shared by the passenger and agency channels."""
from datetime import date
import uuid
from typing import Literal, Optional

from pydantic import BaseModel, Field, field_validator, model_validator

MAX_SEATS, MAX_LOCKED_SEATS = 4, 8

# One name part: letters in any script, single spaces, hyphens, apostrophes or dots between them
NAME_PART = r"^[^\W\d_]+(?:[ '\-.][^\W\d_]+)*\.?$"
MOBILE = r"^\+?[0-9]{8,15}$"


class HoldIn(BaseModel):
    trip_uid: uuid.UUID
    from_seq: int = Field(ge=0)
    to_seq: int = Field(ge=1)
    seat_nos: list[int] = Field(min_length=1, max_length=MAX_SEATS)


class PassengerIn(BaseModel):
    """Passenger names exactly as on the identity document. Syrian citizens give the four parts of the
    national ID (first, father, grandfather, family). Other nationalities give the given and family names
    of the passport or ID; father's and grandfather's names only when the document carries them."""
    nationality: str = Field(default="SY", pattern=r"^[A-Z]{2}$")
    first_name: str = Field(min_length=1, max_length=60, pattern=NAME_PART)
    father_name: Optional[str] = Field(default=None, min_length=1, max_length=60, pattern=NAME_PART)
    grandfather_name: Optional[str] = Field(default=None, min_length=1, max_length=60, pattern=NAME_PART)
    last_name: str = Field(min_length=1, max_length=60, pattern=NAME_PART)
    # Empty only for an infant travelling on an adult's lap (carriers whose infant band needs no seat)
    seat_no: Optional[int] = None
    # Adult, child or infant (4.19); the date of birth decides on the travel date, so it is required for children and infants
    category: Optional[Literal["ADULT", "CHILD", "INFANT"]] = None
    birth_date: Optional[date] = None
    gender: Optional[Literal["M", "F"]] = None
    # A registered member of the booker's family (4.20): counts for family offers; their stored document is used if none is given
    family_member_uid: Optional[uuid.UUID] = None
    # A lap infant: the position (1-based) of the adult on this booking who carries them; default the first adult
    with_adult: Optional[int] = Field(default=None, ge=1, le=MAX_SEATS * 2)
    id_type: Optional[Literal["NATIONAL_ID", "PASSPORT", "RESIDENCE", "LAISSEZ_PASSER", "TRAVEL_DOCUMENT", "OTHER"]] = None
    # Full document number: stored only as AES-256-GCM ciphertext, a blind index and the masked last 4
    id_no: Optional[str] = Field(default=None, min_length=4, max_length=24, pattern=r"^[0-9A-Za-z \-/]+$")
    id_last4: Optional[str] = Field(default=None, pattern=r"^[0-9A-Za-z]{3,4}$")
    mobile: Optional[str] = Field(default=None, pattern=MOBILE)
    # International trips: the passport's expiry date (checked against the rule's minimum validity)
    passport_expiry: Optional[date] = None

    @field_validator("first_name", "father_name", "grandfather_name", "last_name", mode="before")
    @classmethod
    def _tidy(cls, v):
        return " ".join(v.split()) or None if isinstance(v, str) else v

    @model_validator(mode="after")
    def _syrian_four_part_name(self):
        if self.nationality == "SY" and not (self.father_name and self.grandfather_name):
            raise ValueError("NAME_PARTS_REQUIRED: Syrian citizens need first, father, grandfather and family names")
        return self

    @model_validator(mode="after")
    def _document_needs_type(self):
        if self.id_no and not self.id_type:
            raise ValueError("ID_TYPE_REQUIRED: give the document type with the document number")
        return self

    @property
    def full_name(self) -> str:
        return " ".join(p for p in (self.first_name, self.father_name, self.grandfather_name, self.last_name) if p)


class BookingIn(BaseModel):
    hold_token: uuid.UUID
    trip_uid: uuid.UUID
    from_seq: int
    to_seq: int
    fare_brand: str = "STANDARD"
    # seats are capped at MAX_SEATS; lap infants come on top of them
    passengers: list[PassengerIn] = Field(min_length=1, max_length=MAX_SEATS * 2)
    idempotency_key: str = Field(min_length=8, max_length=80)
    # Family bookings (4.20): the head may pay from the family trips account; a member's own booking is paid as the head set
    pay_from: Literal["WALLET", "FAMILY_ACCOUNT"] = "WALLET"

    @model_validator(mode="after")
    def _seats(self):
        if sum(p.seat_no is not None for p in self.passengers) > MAX_SEATS:
            raise ValueError(f"TOO_MANY_SEATS: at most {MAX_SEATS} seats per booking")
        return self


class QuoteIn(BookingIn):
    """A booking request priced before seats are held or paid for."""
    hold_token: Optional[uuid.UUID] = None
    idempotency_key: str = "quote-only"


class AgencyBookingIn(BookingIn):
    """An agency sale also needs a mobile number to reach the traveller about the ticket and trip changes."""
    contact_mobile: str = Field(pattern=MOBILE)
