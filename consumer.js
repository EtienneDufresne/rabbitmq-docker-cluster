var amqp = require('amqplib/callback_api')

var rabbitmqHost = process.env.RABBITMQ_HOST || 'localhost'

amqp.connect({
  protocol: 'amqp',
  hostname: rabbitmqHost,
  vhost: '/',
  port: 5672,
  username: 'guest',
  password: 'guest'
}, function (err, conn) {
  conn.createChannel(function (err, ch) {
    var q = 'my-queue'

    ch.assertQueue(q, {durable: true})
    ch.prefetch(1)
    console.log(' [*] Waiting for messages in %s. To exit press CTRL+C', q)
    ch.consume(q, function (msg) {
      var secs = msg.content.toString().split('.').length - 1

      console.log(' [x] Received %s', msg.content.toString())
      setTimeout(function () {
        console.log(' [x] Done')
        ch.ack(msg)
      }, secs * 1000)
    }, {noAck: false})
  })
})
