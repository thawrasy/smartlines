# Integration requests (N2, migration 1155, owner's decision: option B)

A carrier or an agency no longer creates API clients, keys, webhooks or scopes. Its owner, or an administrator the
owner authorised (`company.api_keys`), files a **connection request**; platform security builds the connection.

## The request

`POST /api/integrations/requests` with: the purpose, the connection type (read data, receive events, two-way), the data
needed (scopes offered to the company's kind only, else `SCOPE_NOT_ALLOWED`), the outside system (name, vendor, host
name, calling addresses or ranges), a technical contact (name, e-mail, mobile), the expected volume and the
environment. The company follows its requests and may withdraw one not yet handled.

## Platform security

1. Reads the request (`GET /api/integrations/requests`) and either refuses it with a reason or builds the client from
   it (`POST /api/integrations/requests/{uid}/client`): name, kind and scopes; the client acts as the person who asked,
   with the request's addresses as its allow-list.
2. Another officer approves the client (the existing four-eyes rule, `FOUR_EYES`).
3. Platform security sets webhooks, limits, mutual TLS and addresses; a company cannot change them (403).
4. An approved client's scopes are never widened in place, by anyone (`SCOPE_WIDENING_NEEDS_APPROVAL`): a wider
   connection is a new request and a new client approved by a second person.

## The key

Once the client is active the company takes its key from its portal (`POST /api/integrations/clients/{uid}/keys`),
shown once. While a key is active the company cannot take another (`KEY_ALREADY_TAKEN`); it can revoke its key at
any time, and then take a new one. Platform security may issue a second key for rotation (at most two active).
