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
    seat_no: int
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
    passengers: list[PassengerIn] = Field(min_length=1, max_length=MAX_SEATS)
    idempotency_key: str = Field(min_length=8, max_length=80)


class AgencyBookingIn(BookingIn):
    """An agency sale also needs a mobile number to reach the traveller about the ticket and trip changes."""
    contact_mobile: str = Field(pattern=MOBILE)
