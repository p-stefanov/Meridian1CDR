create table if not exists user
(
dn integer not null PRIMARY KEY,
callscount integer not null,
seconds integer not null,
bill real not null
);

create table if not exists call
(
callid integer not null PRIMARY KEY,
dn integer not null,
seconds integer not null,
trunk text not null,
date text not null,
called text not null,
price real not null,
type text,
FOREIGN KEY(dn) REFERENCES user(dn)
);
