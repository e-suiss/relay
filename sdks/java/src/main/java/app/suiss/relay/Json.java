package app.suiss.relay;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.MissingNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.IOException;

/** The JSON mapper the SDK reads and writes with. */
public final class Json {
  private static final ObjectMapper MAPPER = new ObjectMapper();

  private Json() {}

  /**
   * The shared mapper. Use it to build request bodies and to read responses into your own types.
   *
   * @return the mapper
   */
  public static ObjectMapper mapper() {
    return MAPPER;
  }

  /**
   * Starts an empty JSON object.
   *
   * @return a new object node
   */
  public static ObjectNode object() {
    return MAPPER.createObjectNode();
  }

  static byte[] write(JsonNode node) {
    try {
      return MAPPER.writeValueAsBytes(node);
    } catch (JsonProcessingException e) {
      throw new IllegalArgumentException("the body cannot be written as JSON", e);
    }
  }

  static String writeString(JsonNode node) {
    try {
      return MAPPER.writeValueAsString(node);
    } catch (JsonProcessingException e) {
      throw new IllegalArgumentException("the value cannot be written as JSON", e);
    }
  }

  static JsonNode parse(byte[] body) {
    if (body == null || body.length == 0) {
      return MissingNode.getInstance();
    }
    try {
      return MAPPER.readTree(body);
    } catch (IOException e) {
      throw new RelayException("the response is not JSON", e);
    }
  }

  static JsonNode parseOrMissing(byte[] body) {
    if (body == null || body.length == 0) {
      return MissingNode.getInstance();
    }
    try {
      JsonNode node = MAPPER.readTree(body);
      return node == null ? MissingNode.getInstance() : node;
    } catch (IOException e) {
      return MissingNode.getInstance();
    }
  }
}
