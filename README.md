# rabbitmq-docker-cluster

This is an example of a dynamically created [Docker](https://www.docker.com/)ized [RabbitMQ](https://www.rabbitmq.com/) cluster using [Consul](https://www.consul.io/)

[See these slides for more information](https://github.com/DockerOttawaMeetup/Slides/tree/master/2016-08-31-Rabbitmq-Docker-Cluster)

## How to run it

### Export these variables
```shell
export RABBITMQ_DEFAULT_USER=guest
export RABBITMQ_DEFAULT_PASSWORD=guest
```

### Build the image
```shell
docker build -t rabbitmq-docker-cluster .
```

### Run Consul, dnsmask and registrator
```shell
docker-compose up -d consul dnsmask registrator
```

### Run the RabbitMQ services and automatically form the cluster
```shell
docker-compose up -d rabbitmq1 rabbitmq2
docker logs -f rabbitmq1
# In another shell
docker logs -f rabbitmq2
```

To access the Consul UI to see the registered services and health checks:
[http://localhost:8500/ui](http://localhost:8500/ui)

To access the RabbitMQ management interface:
- rabbitmq1: [http://localhost:15672/#/](http://localhost:15672/#/)
- rabbitmq2: [http://localhost:15673/#/](http://localhost:15673/#/)

## Clean Up
If you want to start over from scratch run the following:
```
docker-compose stop
docker rm rabbitmq1 -f -v
docker rm rabbitmq2 -f -v
docker volume rm rabbitmqdockercluster_rabbitmq_persistence1
docker volume rm rabbitmqdockercluster_rabbitmq_persistence2
```
