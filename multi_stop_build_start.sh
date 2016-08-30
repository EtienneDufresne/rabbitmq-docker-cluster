eval $(docker-machine env --swarm host1)
docker-compose -f multi/docker-compose.yml up -d rabbitmq1
docker-compose -f multi/docker-compose.yml up -d rabbitmq2
docker rm rabbitmq1 -f -v
docker rm rabbitmq2 -f -v
docker volume rm multi_rabbitmq_persistence1
docker volume rm multi_rabbitmq_persistence2
docker build -t rabbitmq-docker-cluster .
docker-compose -f multi/docker-compose.yml up -d rabbitmq1
sleep 25
docker logs rabbitmq1
docker-compose -f multi/docker-compose.yml up -d rabbitmq2
sleep 25
eval $(docker-machine env host2)
docker logs rabbitmq2
eval $(docker-machine env --swarm host1)
