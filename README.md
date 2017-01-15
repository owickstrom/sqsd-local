# sqsd-local

A local version of `sqsd`, the daemon that runs in Elastic Beanstalk's _Worker
Environments_.

**Current limitations:**

* Only supports `application/json` content type.
* Local SQS endpoint (host/port) is hardcoded. Only tested with ElasticMQ.

## Usage

```bash
sqsd-local http://localhost:8080 my-worker-queue-name my-deadletter-queue-name
```

## Install/Build

Requirements:

* [Stack](https://docs.haskellstack.org/en/stable/README/)

```bash
stack install
```

## License

[Mozilla Public License Version 2.0](LICENSE)
