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
  if (err) {
    console.error(err)
    throw err
  }
  conn.createChannel(function (err, ch) {
    var q = 'my-queue'
    var msg = process.argv.slice(2).join(' ') || 'Hello World!'

    ch.assertQueue(q, {durable: true})
    ch.sendToQueue(q, new Buffer(msg), {persistent: true})
    console.log(" [x] Sent '%s'", msg)
  })
  setTimeout(function () { conn.close(); process.exit(0) }, 500)
})
