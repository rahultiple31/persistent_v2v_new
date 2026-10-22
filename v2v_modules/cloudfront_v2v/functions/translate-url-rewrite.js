function handler(event) {
  var request = event.request;
  var uri = request.uri;

  if (uri.startsWith("/amazon-translate-proxy")) {
    uri = uri.replace("/amazon-translate-proxy", "");
    if (!uri.startsWith("/")) {
      uri = "/" + uri;
    }
    request.uri = uri;
  }

  return request;
}
