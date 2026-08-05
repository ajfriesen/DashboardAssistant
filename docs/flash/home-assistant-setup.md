# Get a Home Assistant Token

The device signs itself in to Home Assistant using a **long-lived access
token**, which you provide in the [seed file](seed.md). Here's how to create one.

Open your Home Assistant profile security page:

[![Open your Home Assistant instance and show your Home Assistant user's security options.](https://my.home-assistant.io/badges/profile_security.svg)](https://my.home-assistant.io/redirect/profile_security/)

Generate a long-lived access token:

![Generate a long-lived access token](../img/generate-long-lived-access-token.png)

Give the token a name:

![Give the token a name](../img/name_token.png)

Copy the token to a text editor or password manager — you'll need it for the
seed file:

![Copy the token](../img/copy_token.png)

The token looks like this:

```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiIyZWRlNGE0ZTFjNmQ0ZDY3OTY4ODhmMTk5OGNhNWVjMSIsImlhdCI6MTc4NDcxODk3MywiZXhwIjoyMTAwMDc4OTczfQ.Rd92pdzdYkC8HI3buVO6m9EVVI71Ye-MP_1nwogfOgU
```
