mkdir certs private
chmod 700 private
echo 01 > serial
touch index.txt
openssl req -x509 -config openssl.cnf -newkey rsa:512 -days 365 \
	-out cacert.pem -outform PEM -subj /CN=fubar_ca/ -nodes
openssl x509 -in cacert.pem -out cacert.cer -outform DER

openssl genrsa -out ../key.pem 512
openssl req -new -key ../key.pem -out ../req.pem -outform PEM \
	-subj /CN=pushcm.skplanetx.com/O=fubar/ -nodes
openssl ca -config openssl.cnf -in ../req.pem -out ../cert.pem -notext \
	-batch -extensions server_ca_extensions
openssl pkcs12 -export -in ../cert.pem -out ../keycert.p12 \
	-inkey ../key.pem -passout pass:fubar
