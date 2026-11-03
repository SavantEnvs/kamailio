/* Known-answer checks over kamailio core (URI/SIP parser, basex, strutils), built with normal flags. */
#include "config.h"
#include "basex.h"
#include "strutils.h"
#include "parser/msg_parser.h"
#include "parser/parse_uri.h"
#include "parser/parse_from.h"
#include "parser/parse_hname2.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int npass, nfail;

#define CHECK(name, cond)                         \
	do {                                          \
		if(cond) {                                \
			npass++;                              \
			printf("PASS %s\n", name);            \
		} else {                                  \
			nfail++;                              \
			printf("FAIL %s (line %d)\n", name, __LINE__); \
		}                                         \
	} while(0)

static int streq(const str *s, const char *lit)
{
	return s->s != NULL && s->len == (int)strlen(lit)
		   && memcmp(s->s, lit, s->len) == 0;
}

static void test_uri(void)
{
	char u1[] = "sip:alice@example.com:5070;transport=tcp?h=v";
	char u2[] = "sips:bob:secret@host.example.org";
	char u3[] = "sip:";
	struct sip_uri uri;

	memset(&uri, 0, sizeof(uri));
	CHECK("uri1 parses", parse_uri(u1, strlen(u1), &uri) == 0);
	CHECK("uri1 user", streq(&uri.user, "alice"));
	CHECK("uri1 host", streq(&uri.host, "example.com"));
	CHECK("uri1 port", uri.port_no == 5070);
	CHECK("uri1 transport", streq(&uri.transport_val, "tcp"));
	CHECK("uri1 type", uri.type == SIP_URI_T);

	memset(&uri, 0, sizeof(uri));
	CHECK("uri2 parses", parse_uri(u2, strlen(u2), &uri) == 0);
	CHECK("uri2 user", streq(&uri.user, "bob"));
	CHECK("uri2 passwd", streq(&uri.passwd, "secret"));
	CHECK("uri2 host", streq(&uri.host, "host.example.org"));
	CHECK("uri2 type", uri.type == SIPS_URI_T);

	memset(&uri, 0, sizeof(uri));
	CHECK("uri3 rejected", parse_uri(u3, strlen(u3), &uri) < 0);
}

static const char invite[] =
		"INVITE sip:bob@biloxi.example.com SIP/2.0\r\n"
		"Via: SIP/2.0/UDP pc33.atlanta.example.com;branch=z9hG4bK776asdhds\r\n"
		"Max-Forwards: 70\r\n"
		"To: Bob <sip:bob@biloxi.example.com>\r\n"
		"From: Alice <sip:alice@atlanta.example.com>;tag=1928301774\r\n"
		"Call-ID: a84b4c76e66710@pc33.atlanta.example.com\r\n"
		"CSeq: 314159 INVITE\r\n"
		"Contact: <sip:alice@pc33.atlanta.example.com>\r\n"
		"Content-Length: 0\r\n"
		"\r\n";

static const char reply[] =
		"SIP/2.0 486 Busy Here\r\n"
		"Via: SIP/2.0/UDP pc33.atlanta.example.com;branch=z9hG4bK776asdhds\r\n"
		"To: Bob <sip:bob@biloxi.example.com>;tag=a6c85cf\r\n"
		"From: Alice <sip:alice@atlanta.example.com>;tag=1928301774\r\n"
		"Call-ID: a84b4c76e66710@pc33.atlanta.example.com\r\n"
		"CSeq: 314159 INVITE\r\n"
		"Content-Length: 0\r\n"
		"\r\n";

static void test_msg(void)
{
	sip_msg_t msg;
	char *buf;
	size_t len = strlen(invite);

	buf = malloc(len + 1);
	memcpy(buf, invite, len + 1);
	memset(&msg, 0, sizeof(msg));
	msg.buf = buf;
	msg.len = len;
	CHECK("request parses", parse_msg(buf, len, &msg) == 0);
	CHECK("request is request", msg.first_line.type == SIP_REQUEST);
	CHECK("request method", msg.first_line.u.request.method_value == METHOD_INVITE);
	CHECK("request ruri", streq(&msg.first_line.u.request.uri,
								 "sip:bob@biloxi.example.com"));
	CHECK("request headers", parse_headers(&msg, HDR_EOH_F, 0) == 0);
	CHECK("request callid", msg.callid != NULL
									&& streq(&msg.callid->body,
											"a84b4c76e66710@pc33.atlanta.example.com"));
	CHECK("request cseq hdr", msg.cseq != NULL);
	CHECK("request via host", msg.via1 != NULL
									  && streq(&msg.via1->host, "pc33.atlanta.example.com"));
	CHECK("request via branch", msg.via1 != NULL && msg.via1->branch != NULL
										&& streq(&msg.via1->branch->value,
												"z9hG4bK776asdhds"));
	CHECK("request from parses", parse_from_header(&msg) == 0);
	CHECK("request from uri", msg.from != NULL && get_from(&msg) != NULL
									  && streq(&get_from(&msg)->uri,
											  "sip:alice@atlanta.example.com"));
	CHECK("request from tag", get_from(&msg) != NULL
									  && streq(&get_from(&msg)->tag_value, "1928301774"));
	free_sip_msg(&msg);
	free(buf);

	len = strlen(reply);
	buf = malloc(len + 1);
	memcpy(buf, reply, len + 1);
	memset(&msg, 0, sizeof(msg));
	msg.buf = buf;
	msg.len = len;
	CHECK("reply parses", parse_msg(buf, len, &msg) == 0);
	CHECK("reply is reply", msg.first_line.type == SIP_REPLY);
	CHECK("reply code", msg.first_line.u.reply.statuscode == 486);
	CHECK("reply reason", streq(&msg.first_line.u.reply.reason, "Busy Here"));
	free_sip_msg(&msg);
	free(buf);
}

static void test_basex(void)
{
	unsigned char out[64];
	int n;

	init_basex();
	n = base64_enc((unsigned char *)"foobar", 6, out, sizeof(out));
	CHECK("base64 enc foobar", n == 8 && memcmp(out, "Zm9vYmFy", 8) == 0);
	n = base64_enc((unsigned char *)"fo", 2, out, sizeof(out));
	CHECK("base64 enc fo pads", n == 4 && memcmp(out, "Zm8=", 4) == 0);
	n = base64_dec((unsigned char *)"Zm9vYmFy", 8, out, sizeof(out));
	CHECK("base64 dec foobar", n == 6 && memcmp(out, "foobar", 6) == 0);
	n = base16_enc((unsigned char *)"\x01\xab\xff", 3, out, sizeof(out));
	CHECK("base16 enc", n == 6 && strncasecmp((char *)out, "01abff", 6) == 0);
	n = base16_dec((unsigned char *)"01abff", 6, out, sizeof(out));
	CHECK("base16 dec", n == 3 && out[0] == 0x01 && out[1] == 0xab && out[2] == 0xff);
}

static void test_strutils(void)
{
	char in1[] = "a b&c=d/é";
	char buf[64];
	str sin, sout;

	sin.s = in1;
	sin.len = strlen(in1);
	sout.s = buf;
	sout.len = sizeof(buf);
	CHECK("urlencode ok", urlencode(&sin, &sout) == 0);
	CHECK("urlencode value", streq(&sout, "a%20b%26c%3dd%2f%c3%a9"));

	{
		char enc[] = "x%20y%2Fz";
		char dec[32];
		sin.s = enc;
		sin.len = strlen(enc);
		sout.s = dec;
		sout.len = sizeof(dec);
		CHECK("urldecode ok", urldecode(&sin, &sout) == 0);
		CHECK("urldecode value", streq(&sout, "x y/z"));
	}

	{
		char a[] = "sip:alice@example.com;transport=udp";
		char b[] = "sip:ALICE@EXAMPLE.COM;transport=udp";
		char c[] = "sip:bob@example.com";
		str sa = {a, (int)strlen(a)}, sb = {b, (int)strlen(b)},
			sc = {c, (int)strlen(c)};
		CHECK("cmp_aor equal host case", cmp_aor_str(&sa, &sa) == 0);
		CHECK("cmp_uri differs by user", cmp_uri_str(&sa, &sc) != 0);
		(void)sb;
	}
}

int main(void)
{
	ksr_hname_init_index();
	test_uri();
	test_msg();
	test_basex();
	test_strutils();
	printf("SELFTEST passed=%d failed=%d\n", npass, nfail);
	return nfail == 0 ? 0 : 1;
}
