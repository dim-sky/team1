import { inject, Service } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { baseURL } from './strings/endpoints';

@Service()
export class HttpHelper {


    private myHttp = inject(HttpClient)


    private baseURL = baseURL



    postSendMessage(body: any) {
        return this.myHttp.post(this.baseURL + "/post", {
            question: body.question,
            role: body.role
        })
    }


    postSendMessageGeneral(body: any) {
        return this.myHttp.post(`${this.baseURL}/generalMessage`, body);
    }



}
