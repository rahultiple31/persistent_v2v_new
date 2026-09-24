function handler(event) {
  var request = event.request;
  var uri = request.uri;

  if (uri.startsWith("/amazon-polly-proxy")) {
    uri = uri.replace("/amazon-polly-proxy", "");
    if (!uri.startsWith("/")) {
      uri = "/" + uri;
    }
    request.uri = uri;
  }

  return request;
}
