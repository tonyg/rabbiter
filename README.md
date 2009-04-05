# Rabbiter

Rabbiter is an ejabberd module providing a bot -
`rabbiter@rabbiter.DOMAIN`, by default - which provides a
microblogging service when you add it to your roster. It builds upon
RabbitMQ and ejabberd.

## Compiling and Running Rabbiter

Get ejabberd sources:

    svn co http://svn.process-one.net/ejabberd/trunk ejabberd

Get, and install, RabbitMQ:

    hg clone http://hg.rabbitmq.com/rabbitmq-codegen/
    hg clone http://hg.rabbitmq.com/rabbitmq-server/
    make -C rabbitmq-server

Symlink the `rabbitmq-server` directory so it is available at your
`lib/erlang` directory:

    ln -s rabbitmq-server /usr/lib/erlang/lib/rabbitmq_server
    # (note underscore instead of hyphen)
    # for macports users
    ln -s rabbitmq-server /opt/local/lib/erlang/lib/rabbitmq_server

Get rabbiter sources from Github.

Symlink `mod_rabbiter.erl` into `ejabberd/src/`.

Build ejabberd using the traditional `configure`, `make`, `make install`.

Add a `mod_rabbiter` stanza to `ejabberd.cfg`:

    {modules,
     [
      ...
      {mod_rabbiter, []},
      ...
     ]}.

Finally, start ejabberd.

If you configured ejabberd to serve `DOMAIN`, and you didn't supply
any special domain for the rabbiter module, you can now add
`rabbiter@rabbiter.DOMAIN` to your roster. It ought to send you a
welcome message.

If you want `rabbiter@someother.domain`, change the `ejabberd.cfg`
stanza for rabbiter to `{mod_rabbiter, [{host, "someother.domain"}]}`.
