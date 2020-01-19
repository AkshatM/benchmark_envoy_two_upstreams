const http = require('http')
const port = 8001
const fs = require('fs');

const request_log_filename = process.argv[process.argv.length - 1]
const request_log = fs.createWriteStream(request_log_filename, {flags:'a'})
request_log.write('Packet Sent Time,Packet Received Time\n')

const requestHandler = (request, response) => {
  // Unix time in milliseconds
  const receipt_timestamp = Date.now().toString();
  
  let request_timestamp = [];
  request.on('data', (chunk) => {
	  request_timestamp.push(chunk);
  }).on('end', () => {
	  request_timestamp = Buffer.concat(request_timestamp).toString();
	  // at this point, `body` has the entire request body stored in it as a string
	  request_log.write(`${request_timestamp},${receipt_timestamp}\n`)
  });
  response.end('OK')
}

const server = http.createServer(requestHandler)

server.listen(port, (err) => {
  if (err) {
    return console.log('something bad happened', err)
  }

  console.log(`server is listening on ${port}`)
})
