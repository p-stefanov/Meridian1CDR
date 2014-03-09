create table if not exists user
(
dn integer not null PRIMARY KEY,
callscount integer not null,
seconds integer not null
);

create table if not exists call
(
callid integer not null PRIMARY KEY,
user integer not null,
seconds integer not null,
trunk text not null,
date text not null,
called text not null,
FOREIGN KEY(user) REFERENCES user(dn)
);
